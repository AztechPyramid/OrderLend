// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

// LP Token interface - direkt contract içinde
interface ILPToken {
    function token0() external view returns (address);
    function token1() external view returns (address);
    function getReserves() external view returns (uint256, uint256);
}

/**
 * @title OrderLend
 * @dev Aave-style lending protocol - Direct contract tracking (NO xTokens)
 * Bu yaklaşım çok daha güvenli ve Aave'in kanıtlanmış mimarisini takip eder
 */
contract OrderLend is Ownable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    // Struct'lar
    struct TokenInfo {
        address tokenAddress;
        address lpAddress;
        uint8 decimals;
        uint256 maxLTV; // 10000 = 100%, 8000 = 80%
        uint256 totalSupply;
        uint256 totalBorrow;
        uint256 supplyIndex; // Compound interest index for suppliers
        uint256 borrowIndex; // Compound interest index for borrowers
        uint256 lastUpdateTime;
        bool isActive;
    }

    struct RewardPool {
        address rewardToken;         // Reward token'ın adresi (ARENA vs.)
        uint256 totalRewards;        // Toplam reward miktarı
        uint256 rewardRate;          // Saniye başına reward (totalRewards / 365 gün)
        uint256 lastUpdateTime;      // Son reward güncelleme zamanı
        uint256 rewardPerTokenStored; // Accumulated reward per token
        uint256 periodFinish;        // Reward period sonu
    }

    struct UserReward {
        uint256 userRewardPerTokenPaid; // User'ın son aldığı reward per token
        uint256 rewards;                // Biriken ama henüz claim edilmemiş rewards
    }

    struct UserPosition {
        mapping(uint256 => uint256) supplyBalance;     // User'ın supply ettiği miktar
        mapping(uint256 => uint256) borrowBalance;     // User'ın borrow ettiği miktar
        mapping(uint256 => uint256) lastSupplyIndex;   // Son supply index
        mapping(uint256 => uint256) lastBorrowIndex;   // Son borrow index
    }

    // State variables
    mapping(uint256 => TokenInfo) public tokens;
    mapping(address => UserPosition) private userPositions;
    mapping(address => uint256) public protocolFees;
    
    // Reward Pool mappings
    mapping(uint256 => RewardPool) public rewardPools;  // tokenId => RewardPool
    mapping(uint256 => mapping(address => UserReward)) public userRewards; // tokenId => user => UserReward
    
    uint256 public tokenCount;
    uint256 public constant MAX_TOKENS = 10000; // 10K token support!
    uint256 public constant LIQUIDATION_BONUS = 1000; // 10%
    uint256 public liquidationThreshold = 8500; // 85% - Liquidation tetiklenir (değiştirilebilir)
    uint256 public constant PROTOCOL_FEE = 100; // 1%
    uint256 public constant SECONDS_PER_YEAR = 31536000;
    
    address public teamAddress; // Team address for protocol fees and liquidation rewards

    // Events
    event TokenAdded(uint256 indexed tokenId, address indexed token, address indexed lpAddress);
    event Supplied(address indexed user, uint256 indexed tokenId, uint256 amount);
    event Withdrawn(address indexed user, uint256 indexed tokenId, uint256 amount);
    event Borrowed(address indexed user, uint256 indexed tokenId, uint256 amount);
    event Repaid(address indexed user, uint256 indexed tokenId, uint256 amount);
    event Liquidated(address indexed liquidator, address indexed borrower, uint256 indexed tokenId, uint256 amount);
    
    // Reward Events
    event RewardAdded(uint256 indexed tokenId, address indexed rewardToken, uint256 amount, uint256 duration);
    event RewardClaimed(address indexed user, uint256 indexed tokenId, uint256 amount);
    event RewardPoolCreated(uint256 indexed tokenId, address indexed rewardToken);
    
    // Admin Events
    event LiquidationThresholdUpdated(uint256 newThreshold);

    constructor() Ownable(msg.sender) {
        teamAddress = msg.sender; // Initially set to deployer
    }

    // Token ekleme - Owner only
    function addToken(
        address tokenAddress,
        address lpAddress,
        uint256 maxLTV
    ) external onlyOwner {
        require(tokenAddress != address(0) && lpAddress != address(0), "Invalid addresses");
        require(maxLTV <= 9000, "Max LTV too high");

        uint256 tokenId = tokenCount++;
        
        tokens[tokenId] = TokenInfo({
            tokenAddress: tokenAddress,
            lpAddress: lpAddress,
            decimals: _getDecimals(tokenAddress),
            maxLTV: maxLTV,
            totalSupply: 0,
            totalBorrow: 0,
            supplyIndex: 1e18,  // Initial index = 1.0
            borrowIndex: 1e18,  // Initial index = 1.0
            lastUpdateTime: block.timestamp,
            isActive: true
        });

        emit TokenAdded(tokenId, tokenAddress, lpAddress);
    }

    // LP'den fiyat hesaplama
    function getTokenPrice(uint256 tokenId) public view returns (uint256) {
        TokenInfo memory token = tokens[tokenId];
        require(token.isActive, "Token not active");

        (uint256 reserve0, uint256 reserve1) = 
            ILPToken(token.lpAddress).getReserves();
        
        address token0 = ILPToken(token.lpAddress).token0();
        
        if (token0 == token.tokenAddress) {
            return (reserve1 * 1e18) / reserve0;
        } else {
            return (reserve0 * 1e18) / reserve1;
        }
    }

    // 🟢 SECURE SUPPLY - No xTokens, direct tracking + Rewards
    function supply(uint256 tokenId, uint256 amount) external nonReentrant {
        require(amount > 0, "Amount must be positive");
        updateIndexes(tokenId);
        updateReward(msg.sender, tokenId); // Update rewards before balance change

        TokenInfo storage token = tokens[tokenId];
        require(token.isActive, "Token not active");

        // Transfer tokens to contract
        IERC20(token.tokenAddress).safeTransferFrom(msg.sender, address(this), amount);
        
        // Update user's supply balance with current index
        UserPosition storage user = userPositions[msg.sender];
        
        // Apply accrued interest to existing balance
        uint256 existingBalance = _getSupplyBalanceWithInterest(msg.sender, tokenId);
        
        // Add new supply
        user.supplyBalance[tokenId] = existingBalance + amount;
        user.lastSupplyIndex[tokenId] = token.supplyIndex;
        
        // Update global supply
        token.totalSupply += amount;

        emit Supplied(msg.sender, tokenId, amount);
    }

    // 🟢 SECURE WITHDRAW - Direct balance check, impossible to manipulate + Rewards
    function withdraw(uint256 tokenId, uint256 amount) external nonReentrant {
        require(amount > 0, "Amount must be positive");
        updateIndexes(tokenId);
        updateReward(msg.sender, tokenId); // Update rewards before balance change

        TokenInfo storage token = tokens[tokenId];
        require(token.isActive, "Token not active");

        // 🛡️ SECURITY: Get user's ACTUAL supply balance with interest
        uint256 userSupplyBalance = _getSupplyBalanceWithInterest(msg.sender, tokenId);
        require(userSupplyBalance >= amount, "Insufficient supply balance");
        
        // 🛡️ SECURITY: Check health before withdrawal
        require(_isHealthy(msg.sender, tokenId, amount, true), "Would become unhealthy");

        // Update user's supply balance
        UserPosition storage user = userPositions[msg.sender];
        user.supplyBalance[tokenId] = userSupplyBalance - amount;
        user.lastSupplyIndex[tokenId] = token.supplyIndex;
        
        // Update global supply
        token.totalSupply -= amount;
        
        // Transfer tokens to user
        IERC20(token.tokenAddress).safeTransfer(msg.sender, amount);

        emit Withdrawn(msg.sender, tokenId, amount);
    }

    // 🟢 SECURE BORROW - Cross-collateral with direct balance tracking
    function borrow(uint256 tokenId, uint256 amount) external nonReentrant {
        require(amount > 0, "Amount must be positive");
        updateIndexes(tokenId);

        TokenInfo storage token = tokens[tokenId];
        require(token.isActive, "Token not active");
        require(token.totalSupply >= token.totalBorrow + amount, "Insufficient liquidity");
        
        // Cross-collateral health check
        require(_isHealthyPortfolioBorrow(msg.sender, tokenId, amount), "Insufficient collateral");

        // Update user's borrow balance
        UserPosition storage user = userPositions[msg.sender];
        uint256 existingBorrow = _getBorrowBalanceWithInterest(msg.sender, tokenId);
        
        user.borrowBalance[tokenId] = existingBorrow + amount;
        user.lastBorrowIndex[tokenId] = token.borrowIndex;
        
        // Update global borrow
        token.totalBorrow += amount;
        
        // Transfer tokens to user
        IERC20(token.tokenAddress).safeTransfer(msg.sender, amount);

        emit Borrowed(msg.sender, tokenId, amount);
    }

    // Borç ödeme
    function repay(uint256 tokenId, uint256 amount) external nonReentrant {
        require(amount > 0, "Amount must be positive");
        updateIndexes(tokenId);

        TokenInfo storage token = tokens[tokenId];
        require(token.isActive, "Token not active");

        uint256 userBorrowBalance = _getBorrowBalanceWithInterest(msg.sender, tokenId);
        require(userBorrowBalance > 0, "No debt to repay");
        
        uint256 actualRepay = amount > userBorrowBalance ? userBorrowBalance : amount;
        
        // Transfer repayment to contract
        IERC20(token.tokenAddress).safeTransferFrom(msg.sender, address(this), actualRepay);
        
        // Update user's borrow balance
        UserPosition storage user = userPositions[msg.sender];
        user.borrowBalance[tokenId] = userBorrowBalance - actualRepay;
        user.lastBorrowIndex[tokenId] = token.borrowIndex;
        
        // Update global borrow
        token.totalBorrow -= actualRepay;

        emit Repaid(msg.sender, tokenId, actualRepay);
    }

    // Interest index güncelleme (Aave tarzı) + Protocol fee collection
    function updateIndexes(uint256 tokenId) public {
        TokenInfo storage token = tokens[tokenId];
        
        uint256 timeElapsed = block.timestamp - token.lastUpdateTime;
        if (timeElapsed == 0) return;
        
        uint256 borrowRate = _getBorrowRate(tokenId);
        uint256 supplyRate = _getSupplyRate(tokenId);
        
        // Calculate total interest generated from borrowers
        uint256 totalInterest = (token.totalBorrow * borrowRate * timeElapsed) / (SECONDS_PER_YEAR * 1e18);
        
        // Protocol fee = 1% of total interest (not principal!)
        uint256 protocolFee = (totalInterest * PROTOCOL_FEE) / 10000;
        protocolFees[token.tokenAddress] += protocolFee;
        
        // Compound interest calculation
        uint256 borrowInterestFactor = 1e18 + (borrowRate * timeElapsed) / SECONDS_PER_YEAR;
        uint256 supplyInterestFactor = 1e18 + (supplyRate * timeElapsed) / SECONDS_PER_YEAR;
        
        token.borrowIndex = (token.borrowIndex * borrowInterestFactor) / 1e18;
        token.supplyIndex = (token.supplyIndex * supplyInterestFactor) / 1e18;
        token.lastUpdateTime = block.timestamp;
    }

    // 🛡️ SECURE: User balance calculations with interest
    function _getSupplyBalanceWithInterest(address user, uint256 tokenId) internal view returns (uint256) {
        UserPosition storage userPos = userPositions[user];
        uint256 balance = userPos.supplyBalance[tokenId];
        if (balance == 0) return 0;
        
        uint256 lastIndex = userPos.lastSupplyIndex[tokenId];
        uint256 currentIndex = tokens[tokenId].supplyIndex;
        
        return (balance * currentIndex) / lastIndex;
    }

    function _getBorrowBalanceWithInterest(address user, uint256 tokenId) internal view returns (uint256) {
        UserPosition storage userPos = userPositions[user];
        uint256 balance = userPos.borrowBalance[tokenId];
        if (balance == 0) return 0;
        
        uint256 lastIndex = userPos.lastBorrowIndex[tokenId];
        uint256 currentIndex = tokens[tokenId].borrowIndex;
        
        return (balance * currentIndex) / lastIndex;
    }

    // Cross-collateral health check
    function _isHealthyPortfolioBorrow(address user, uint256 borrowTokenId, uint256 borrowAmount) internal view returns (bool) {
        uint256 totalCollateralValue = 0;
        uint256 totalBorrowValue = 0;

        for (uint256 i = 0; i < tokenCount; i++) {
            if (!tokens[i].isActive) continue;
            
            uint256 price = getTokenPrice(i);
            uint256 supplied = _getSupplyBalanceWithInterest(user, i);
            uint256 borrowed = _getBorrowBalanceWithInterest(user, i);
            
            if (i == borrowTokenId) {
                borrowed += borrowAmount;
            }
            
            if (supplied > 0) {
                uint256 collateralValue = (supplied * price * tokens[i].maxLTV) / (10000 * 10**tokens[i].decimals);
                totalCollateralValue += collateralValue;
            }
            
            if (borrowed > 0) {
                uint256 borrowValue = (borrowed * price) / 10**tokens[i].decimals;
                totalBorrowValue += borrowValue;
            }
        }

        return totalCollateralValue >= totalBorrowValue;
    }

    function _isHealthy(address user, uint256 changeTokenId, uint256 changeAmount, bool isWithdraw) 
        internal view returns (bool) {
        uint256 totalCollateralValue = 0;
        uint256 totalBorrowValue = 0;

        for (uint256 i = 0; i < tokenCount; i++) {
            if (!tokens[i].isActive) continue;
            
            uint256 price = getTokenPrice(i);
            uint256 supplied = _getSupplyBalanceWithInterest(user, i);
            uint256 borrowed = _getBorrowBalanceWithInterest(user, i);
            
            if (i == changeTokenId && isWithdraw) {
                supplied = supplied >= changeAmount ? supplied - changeAmount : 0;
            }
            
            if (supplied > 0) {
                uint256 collateralValue = (supplied * price * tokens[i].maxLTV) / (10000 * 10**tokens[i].decimals);
                totalCollateralValue += collateralValue;
            }
            
            if (borrowed > 0) {
                uint256 borrowValue = (borrowed * price) / 10**tokens[i].decimals;
                totalBorrowValue += borrowValue;
            }
        }

        return totalCollateralValue >= totalBorrowValue;
    }

    // Rate calculations
    function _getBorrowRate(uint256 tokenId) internal view returns (uint256) {
        uint256 utilization = getUtilizationRate(tokenId);
        
        uint256 baseRate = 200000000000000000; // 2% APY
        uint256 slope1 = 80000000000000000;   // 8% at 80% utilization  
        uint256 slope2 = 1000000000000000000; // 100% jump at 80%+ utilization
        uint256 kink = 800000000000000000;    // 80% utilization kink point
        
        if (utilization <= kink) {
            return baseRate + (utilization * slope1) / 1e18;
        } else {
            uint256 excessUtil = utilization - kink;
            return baseRate + (kink * slope1) / 1e18 + (excessUtil * slope2) / 1e18;
        }
    }

    function _getSupplyRate(uint256 tokenId) internal view returns (uint256) {
        uint256 borrowRate = _getBorrowRate(tokenId);
        uint256 utilization = getUtilizationRate(tokenId);
        uint256 retention = 10000 - PROTOCOL_FEE; // 99% suppliers'a gidiyor
        
        return (borrowRate * utilization * retention) / (1e18 * 10000);
    }

    // View functions
    function getUserPosition(address user, uint256 tokenId) 
        external view returns (uint256 supplied, uint256 borrowed) {
        supplied = _getSupplyBalanceWithInterest(user, tokenId);
        borrowed = _getBorrowBalanceWithInterest(user, tokenId);
    }

    function getUtilizationRate(uint256 tokenId) public view returns (uint256) {
        TokenInfo memory token = tokens[tokenId];
        if (token.totalSupply == 0) return 0;
        return (token.totalBorrow * 1e18) / token.totalSupply;
    }

    function getSupplyRate(uint256 tokenId) external view returns (uint256) {
        return _getSupplyRate(tokenId);
    }

    function getBorrowRate(uint256 tokenId) external view returns (uint256) {
        return _getBorrowRate(tokenId);
    }

    // Liquidation with improved threshold and team rewards
    function liquidate(address borrower, uint256 debtTokenId, uint256 collateralTokenId, uint256 amount) external nonReentrant {
        updateIndexes(debtTokenId);
        updateIndexes(collateralTokenId);
        
        // Check if position is liquidatable (below 85% health)
        require(_isLiquidatable(borrower), "Position is not liquidatable");
        
        TokenInfo storage debtToken = tokens[debtTokenId];
        TokenInfo storage collateralToken = tokens[collateralTokenId];
        require(debtToken.isActive && collateralToken.isActive, "Tokens not active");
        
        uint256 debt = _getBorrowBalanceWithInterest(borrower, debtTokenId);
        require(debt > 0, "No debt to liquidate");
        
        uint256 liquidateAmount = amount > debt ? debt : amount;
        
        // Calculate and execute liquidation
        uint256 collateralToSeize = _calculateCollateralToSeize(
            liquidateAmount, 
            debtTokenId, 
            collateralTokenId
        );
        
        _executeLiquidation(
            borrower,
            liquidateAmount,
            collateralToSeize,
            debtTokenId,
            collateralTokenId
        );
        
        emit Liquidated(msg.sender, borrower, debtTokenId, liquidateAmount);
    }
    
    function _calculateCollateralToSeize(
        uint256 liquidateAmount,
        uint256 debtTokenId,
        uint256 collateralTokenId
    ) private view returns (uint256) {
        uint256 debtPrice = getTokenPrice(debtTokenId);
        uint256 collateralPrice = getTokenPrice(collateralTokenId);
        
        // Convert debt value to collateral amount with 10% bonus
        uint256 debtValueInUSD = (liquidateAmount * debtPrice) / 10**tokens[debtTokenId].decimals;
        uint256 collateralToSeize = (debtValueInUSD * (10000 + LIQUIDATION_BONUS)) / 10000;
        collateralToSeize = (collateralToSeize * 10**tokens[collateralTokenId].decimals) / collateralPrice;
        
        return collateralToSeize;
    }
    
    function _executeLiquidation(
        address borrower,
        uint256 liquidateAmount,
        uint256 collateralToSeize,
        uint256 debtTokenId,
        uint256 collateralTokenId
    ) private {
        // Check borrower has enough collateral
        uint256 borrowerCollateral = _getSupplyBalanceWithInterest(borrower, collateralTokenId);
        require(borrowerCollateral >= collateralToSeize, "Insufficient collateral");
        
        // Liquidator pays debt
        IERC20(tokens[debtTokenId].tokenAddress).safeTransferFrom(msg.sender, address(this), liquidateAmount);
        
        // Update borrower's positions
        UserPosition storage borrowerPos = userPositions[borrower];
        borrowerPos.borrowBalance[debtTokenId] = _getBorrowBalanceWithInterest(borrower, debtTokenId) - liquidateAmount;
        borrowerPos.lastBorrowIndex[debtTokenId] = tokens[debtTokenId].borrowIndex;
        
        borrowerPos.supplyBalance[collateralTokenId] = borrowerCollateral - collateralToSeize;
        borrowerPos.lastSupplyIndex[collateralTokenId] = tokens[collateralTokenId].supplyIndex;
        
        // Update global balances
        tokens[debtTokenId].totalBorrow -= liquidateAmount;
        tokens[collateralTokenId].totalSupply -= collateralToSeize;
        
        // Split collateral: 90% to liquidator, 10% to team
        uint256 liquidatorReward = (collateralToSeize * 9000) / 10000;
        uint256 teamReward = collateralToSeize - liquidatorReward;
        
        // Transfer rewards
        IERC20(tokens[collateralTokenId].tokenAddress).safeTransfer(msg.sender, liquidatorReward);
        IERC20(tokens[collateralTokenId].tokenAddress).safeTransfer(teamAddress, teamReward);
    }
    
    // Check if position is liquidatable (health factor below 85%)
    function _isLiquidatable(address user) internal view returns (bool) {
        uint256 totalCollateralValue = 0;
        uint256 totalBorrowValue = 0;

        for (uint256 i = 0; i < tokenCount; i++) {
            if (!tokens[i].isActive) continue;
            
            uint256 price = getTokenPrice(i);
            uint256 supplied = _getSupplyBalanceWithInterest(user, i);
            uint256 borrowed = _getBorrowBalanceWithInterest(user, i);
            
            if (supplied > 0) {
                // Collateral value in USD (no threshold applied for liquidation check)
                uint256 collateralValue = (supplied * price) / 10**tokens[i].decimals;
                totalCollateralValue += collateralValue;
            }
            
            if (borrowed > 0) {
                uint256 borrowValue = (borrowed * price) / 10**tokens[i].decimals;
                totalBorrowValue += borrowValue;
            }
        }

        // Check if borrow value exceeds 85% of collateral value
        return totalBorrowValue * 10000 > totalCollateralValue * liquidationThreshold;
    }

    // Public function to check liquidation status
    function checkLiquidation(address user) external view returns (bool) {
        return _isLiquidatable(user);
    }

    // Public getters for user balances
    function getUserSupply(address user, uint256 tokenId) external view returns (uint256) {
        return _getSupplyBalanceWithInterest(user, tokenId);
    }

    function getUserBorrow(address user, uint256 tokenId) external view returns (uint256) {
        return _getBorrowBalanceWithInterest(user, tokenId);
    }

    // 🎁 REWARD SYSTEM FUNCTIONS
    
    // Create reward pool for a specific token
    function createRewardPool(uint256 tokenId, address rewardToken) external onlyOwner {
        require(tokens[tokenId].isActive, "Token not active");
        require(rewardToken != address(0), "Invalid reward token");
        require(rewardPools[tokenId].rewardToken == address(0), "Reward pool already exists");
        
        rewardPools[tokenId] = RewardPool({
            rewardToken: rewardToken,
            totalRewards: 0,
            rewardRate: 0,
            lastUpdateTime: block.timestamp,
            rewardPerTokenStored: 0,
            periodFinish: 0
        });
        
        emit RewardPoolCreated(tokenId, rewardToken);
    }
    
    // Add rewards to a token's reward pool (anyone can call!)
    function addReward(uint256 tokenId, uint256 amount) external nonReentrant {
        require(tokens[tokenId].isActive, "Token not active");
        require(rewardPools[tokenId].rewardToken != address(0), "Reward pool not created");
        require(amount > 0, "Amount must be positive");
        
        RewardPool storage pool = rewardPools[tokenId];
        
        // Update reward per token before adding new rewards
        _updateRewardPerToken(tokenId);
        
        // Transfer reward tokens to contract
        IERC20(pool.rewardToken).safeTransferFrom(msg.sender, address(this), amount);
        
        // Calculate new reward rate for 365 days
        uint256 duration = 365 days;
        
        // If there are existing rewards that haven't finished, add them to new rewards
        if (block.timestamp < pool.periodFinish) {
            uint256 remaining = pool.periodFinish - block.timestamp;
            uint256 leftover = remaining * pool.rewardRate;
            amount += leftover;
        }
        
        pool.rewardRate = amount / duration;
        pool.totalRewards += amount;
        pool.lastUpdateTime = block.timestamp;
        pool.periodFinish = block.timestamp + duration;
        
        emit RewardAdded(tokenId, pool.rewardToken, amount, duration);
    }
    
    // Update user's reward before balance changes
    function updateReward(address user, uint256 tokenId) public {
        if (rewardPools[tokenId].rewardToken == address(0)) return; // No reward pool
        
        _updateRewardPerToken(tokenId);
        
        UserReward storage userReward = userRewards[tokenId][user];
        userReward.rewards = earned(user, tokenId);
        userReward.userRewardPerTokenPaid = rewardPools[tokenId].rewardPerTokenStored;
    }
    
    // Calculate current reward per token
    function _updateRewardPerToken(uint256 tokenId) internal {
        RewardPool storage pool = rewardPools[tokenId];
        TokenInfo storage token = tokens[tokenId];
        
        if (token.totalSupply == 0) {
            pool.lastUpdateTime = block.timestamp;
            return;
        }
        
        uint256 lastTimeRewardApplicable = block.timestamp < pool.periodFinish ? 
            block.timestamp : pool.periodFinish;
            
        if (lastTimeRewardApplicable > pool.lastUpdateTime) {
            pool.rewardPerTokenStored += ((lastTimeRewardApplicable - pool.lastUpdateTime) * 
                pool.rewardRate * 1e18) / token.totalSupply;
        }
        
        pool.lastUpdateTime = lastTimeRewardApplicable;
    }
    
    // Calculate earned rewards for a user
    function earned(address user, uint256 tokenId) public view returns (uint256) {
        if (rewardPools[tokenId].rewardToken == address(0)) return 0;
        
        uint256 userBalance = _getSupplyBalanceWithInterest(user, tokenId);
        uint256 currentRewardPerToken = rewardPerToken(tokenId);
        
        UserReward storage userReward = userRewards[tokenId][user];
        
        return (userBalance * (currentRewardPerToken - userReward.userRewardPerTokenPaid)) / 1e18 + 
            userReward.rewards;
    }
    
    // Get current reward per token (view function)
    function rewardPerToken(uint256 tokenId) public view returns (uint256) {
        RewardPool storage pool = rewardPools[tokenId];
        TokenInfo storage token = tokens[tokenId];
        
        if (token.totalSupply == 0) {
            return pool.rewardPerTokenStored;
        }
        
        uint256 lastTimeRewardApplicable = block.timestamp < pool.periodFinish ? 
            block.timestamp : pool.periodFinish;
            
        return pool.rewardPerTokenStored + 
            ((lastTimeRewardApplicable - pool.lastUpdateTime) * pool.rewardRate * 1e18) / token.totalSupply;
    }
    
    // Claim accumulated rewards
    function claimReward(uint256 tokenId) external nonReentrant {
        require(rewardPools[tokenId].rewardToken != address(0), "Reward pool not created");
        
        updateReward(msg.sender, tokenId);
        
        uint256 reward = userRewards[tokenId][msg.sender].rewards;
        require(reward > 0, "No rewards to claim");
        
        userRewards[tokenId][msg.sender].rewards = 0;
        
        IERC20(rewardPools[tokenId].rewardToken).safeTransfer(msg.sender, reward);
        
        emit RewardClaimed(msg.sender, tokenId, reward);
    }
    
    // Claim rewards for multiple tokens
    function claimMultipleRewards(uint256[] calldata tokenIds) external {
        for (uint256 i = 0; i < tokenIds.length; i++) {
            if (rewardPools[tokenIds[i]].rewardToken != address(0) && 
                userRewards[tokenIds[i]][msg.sender].rewards > 0) {
                updateReward(msg.sender, tokenIds[i]);
                
                uint256 reward = userRewards[tokenIds[i]][msg.sender].rewards;
                if (reward > 0) {
                    userRewards[tokenIds[i]][msg.sender].rewards = 0;
                    IERC20(rewardPools[tokenIds[i]].rewardToken).safeTransfer(msg.sender, reward);
                    emit RewardClaimed(msg.sender, tokenIds[i], reward);
                }
            }
        }
    }

    // Owner functions
    function setMaxLTV(uint256 tokenId, uint256 newMaxLTV) external onlyOwner {
        require(newMaxLTV <= 9000, "Max LTV too high");
        tokens[tokenId].maxLTV = newMaxLTV;
    }
    
    // Set liquidation threshold - Owner can change liquidation trigger point
    function setLiquidationThreshold(uint256 newThreshold) external onlyOwner {
        require(newThreshold >= 5000 && newThreshold <= 9500, "Invalid liquidation threshold");
        liquidationThreshold = newThreshold;
        emit LiquidationThresholdUpdated(newThreshold);
    }
    
    function setTeamAddress(address newTeamAddress) external onlyOwner {
        require(newTeamAddress != address(0), "Invalid team address");
        teamAddress = newTeamAddress;
    }
    
    // Claim protocol fees - only team can claim
    function claimProtocolFees(address tokenAddress) external {
        require(msg.sender == teamAddress, "Only team can claim");
        uint256 fees = protocolFees[tokenAddress];
        require(fees > 0, "No fees to claim");
        
        protocolFees[tokenAddress] = 0;
        IERC20(tokenAddress).safeTransfer(teamAddress, fees);
    }
    
    // Batch claim all protocol fees
    function claimAllProtocolFees() external {
        require(msg.sender == teamAddress, "Only team can claim");
        
        for (uint256 i = 0; i < tokenCount; i++) {
            if (!tokens[i].isActive) continue;
            
            address tokenAddress = tokens[i].tokenAddress;
            uint256 fees = protocolFees[tokenAddress];
            
            if (fees > 0) {
                protocolFees[tokenAddress] = 0;
                IERC20(tokenAddress).safeTransfer(teamAddress, fees);
            }
        }
    }
    
    // View functions for rewards
    function getRewardPoolInfo(uint256 tokenId) external view returns (
        address rewardToken,
        uint256 totalRewards,
        uint256 rewardRate,
        uint256 periodFinish,
        uint256 rewardPerTokenStored
    ) {
        RewardPool storage pool = rewardPools[tokenId];
        return (
            pool.rewardToken,
            pool.totalRewards,
            pool.rewardRate,
            pool.periodFinish,
            pool.rewardPerTokenStored
        );
    }
    
    function getUserRewardInfo(address user, uint256 tokenId) external view returns (
        uint256 earnedRewards,
        uint256 rewardsPending
    ) {
        return (
            earned(user, tokenId),
            userRewards[tokenId][user].rewards
        );
    }

    function _getDecimals(address token) internal view returns (uint8) {
        try IERC20Metadata(token).decimals() returns (uint8 decimals) {
            return decimals;
        } catch {
            return 18;
        }
    }
}


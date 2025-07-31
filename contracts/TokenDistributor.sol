// SPDX-License-Identifier: BSD-3-Clause

pragma solidity 0.8.22;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import '@openzeppelin/contracts/utils/math/SafeCast.sol';
import '@openzeppelin/contracts/security/ReentrancyGuard.sol';
import "./AddressSet.sol";

/**
 * @title  Multiple Token Distributor
 * @notice Users can claim rewards before defined expire time
 *         Users can assign executors to claim rewards on their behalf
 *         Executor can claim only for receiver who is owner of reward 
 *         Expired reward can be withdrawn by the owner of contract
 */
contract TokenDistributor is Ownable ,ReentrancyGuard {
    using SafeERC20 for IERC20;
    using AddressSet for AddressSet.State;
    using SafeCast for uint256;

    uint256 public constant MAX_ALL_REWARD_TOKENS = 10;
    uint256 public constant MAX_BUFFER_DAY = 90;

    enum RewardStatus {
        CLAIMABLE,
        CLAIMED,
        EXPIRED
    }    
    struct Reward {
        uint48 timestamp; 
        uint128 amount;
        uint48 processTimestamp;
        RewardStatus status;
    }
    struct AccountStatus {
        uint128 processedIndex;
        uint128 lastIndex;
    }

    address[] public  allRewardTokens;
    mapping (address => bool) public  rewardTokens;

    uint256 public immutable bufferTime;  //For expiration

    mapping(address => uint256) public totalRewardToClaim; // token -> amount 
    mapping(address => uint256) public totalExpired; // token -> amount , withdrawable expired amount
    mapping(address => AddressSet.State) private ownerClaimExecutorSet; // mapping owner address => executor set
    mapping (address => mapping (address => mapping (uint => Reward))) public rewards;  // account -> token -> reward
    mapping (address => mapping (address => AccountStatus)) public accountStatus;  // account -> token -> status
   
    event CanClaim(address indexed rewardOwner, address indexed token, uint256 amount, uint256 timestamp);
    event ExpiredClaim(address indexed rewardOwner, address indexed token , uint256 amount, uint256 timestamp);
    event HasClaimedWithTimestamp(address indexed rewardOwner, address indexed token , uint256 amount, uint256 timestamp);
    event HasClaimed(address indexed rewardOwner, address indexed recipient, address indexed token , uint256 amount);  
    event Withdrawal(address indexed token, address indexed recipient, uint256 amount);
    event WithdrawalExpiredToken(address indexed token, address indexed recipient,  uint256 amount);
    event AddRewardToken(address rewardToken);
    event ClaimExecutorsChanged(address owner, address[] executors);

    /// @dev Initializes owner and bufferTime 
    constructor(
        address _owner,
        uint256 _bufferDay
    ) Ownable() {
        require(_owner != address(0), "TD: zero owner address");
        require(_bufferDay > 1, "TD: bufferDay must be greater than 1");
        require(_bufferDay <= MAX_BUFFER_DAY, "TD: Max bufferDay exceeded");
        _transferOwnership(_owner);
        bufferTime = _bufferDay * 1 days;
    }

    /// @dev Only callable by owner or  executor
    modifier onlyOwnerOrExecutor(address _rewardOwner, address _recipient) {
        _onlyOwnerOrExecutor(_rewardOwner, _recipient);
        _;
    }

    /// @dev Only callable by owner or  executor
    function _onlyOwnerOrExecutor(address _rewardOwner, address _recipient) private view {
        if (msg.sender == _rewardOwner) {
            return;
        }
         // checks if _executor is allowed executor
        require(ownerClaimExecutorSet[_rewardOwner].index[msg.sender] != 0, "TD: only owner or executor");
        // checks if _recipient is allowed recipient
        require(_recipient == _rewardOwner ,"TD: recipient not allowed");
    }

     /// @notice Get a nurmber of all reward tokens
    function allRewardTokensLength() external view returns (uint256) {
        return allRewardTokens.length;
    }

    /// @notice Get a list of all reward tokens
    function getAllRewardTokens() external view returns (address[] memory) {
        return allRewardTokens;
    }
    /// @notice Set executor for reward owners
    /// @dev msg.sender must be reward owner
    /// @param _executors array of executors addresses
    function setClaimExecutors(address[] memory _executors) external {
        // replace executors
        ownerClaimExecutorSet[msg.sender].replaceAll(_executors);
        emit ClaimExecutorsChanged(msg.sender, _executors);
    }

    /// @notice Set reward token
    /// @dev limited definable
    /// @dev must be carefully defined as there is no removal
    /// @param _token address of token
    function addRewardToken(
        address _token
    ) external onlyOwner{
        if (!rewardTokens[_token]) {
            require(allRewardTokens.length < MAX_ALL_REWARD_TOKENS,"TD: too many rewardTokens");
            allRewardTokens.push(_token);
            rewardTokens[_token] = true;
            emit AddRewardToken(_token);
        }
    }

    /// @notice Withdraws expired token to given receiver
    /// @param _token address of token
    /// @param _receiver address of receiver
    function withdrawExpiredToken(address _token, address _receiver ) external onlyOwner nonReentrant{
        require(rewardTokens[_token], "TD: invalid _token");
        require(_receiver != address(0), "TD: zero receiver address");
        uint256 amount = totalExpired[_token];
        require(amount != 0, "TD: totalExpired should be greater than zero");
        totalExpired[_token] = 0;
        IERC20(_token).safeTransfer(_receiver, amount);
        emit WithdrawalExpiredToken(_token, _receiver, amount);
    }    

    /// @notice to help users who accidentally send their tokens to this contract
    /// @dev if token is reward token, user funds are not withdrawn
    /// @param _token address of token
    /// @param _receiver address of receiver
    /// @param _amount amount to withdraw
    function withdrawEmergencyToken(IERC20 _token, address _receiver, uint256 _amount) external onlyOwner nonReentrant{
        require(_receiver != address(0), "TD: zero receiver address");
        if(rewardTokens[address(_token)]){
            uint256 tokenBalance = _token.balanceOf(address(this));
            //Expired Token added into lock amount, withdrawExpiredToken function must be used for Expired Token
            uint256 lockBalance = totalRewardToClaim[address(_token)] + totalExpired[address(_token)];
            require(lockBalance + _amount <= tokenBalance , "Not allowed to withdraw users' funds");
        }

        _token.safeTransfer(_receiver, _amount);
        emit Withdrawal(address(_token), _receiver, _amount);
    }

    /// @notice set rewards to recepients in bulk
    /// @dev only callable by owner
    /// @dev only one reward can be assigned to the same account on the same day
    /// @param _token address of token
    /// @param _recipients array of reward owners addresses
    /// @param _claimableAmount amount of reward
    function setRecipients(address _token, address[] calldata _recipients, uint256[] calldata _claimableAmount)
        external
        onlyOwner
    {
        require(rewardTokens[_token], "TD: invalid _token");
        require(
            _recipients.length == _claimableAmount.length, "TD: invalid array length"
        );

        uint256 sumReward;
        uint256 sumExpired;
        uint256 currentDay = (block.timestamp / 1 days) * 1 days;
        for (uint256 i; i < _recipients.length; i++) {
            address recipient = _recipients[i];
            AccountStatus memory status = accountStatus[recipient][_token];

            require(rewards[recipient][_token][status.lastIndex].timestamp != currentDay,"TD: recipient already set");

            uint256 claimableAmount = _claimableAmount[i];

            if(status.lastIndex > 0 && status.processedIndex < status.lastIndex 
                && rewards[recipient][_token][status.processedIndex + 1].timestamp + bufferTime < currentDay
                )
            {
                uint256 firstIndex = status.processedIndex + 1;
                uint256 lastIndex = status.lastIndex;
                for(uint256 j = firstIndex; j <= lastIndex; j++) {
                    Reward memory reward = rewards[recipient][_token][j];

                    if(reward.timestamp + bufferTime < currentDay ){
                        unchecked {
                            sumExpired += reward.amount;
                        }
                        reward.processTimestamp = block.timestamp.toUint48();
                        reward.status = RewardStatus.EXPIRED;
                        rewards[recipient][_token][j] = reward;
                        status.processedIndex = j.toUint128();    
                        emit ExpiredClaim(recipient, _token, reward.amount, reward.timestamp);
                    }else{
                        break;
                    }
                }  
            }

            rewards[recipient][_token][++status.lastIndex] = Reward(currentDay.toUint48(),claimableAmount.toUint128(),0,RewardStatus.CLAIMABLE);
            accountStatus[recipient][_token] = status;

            emit CanClaim(recipient, _token, claimableAmount, currentDay);
            
            unchecked {
                sumReward += claimableAmount;
            }
        }
        uint256 totalRewardAmount = totalRewardToClaim[_token] + sumReward - sumExpired;
        uint256 totalExpiredAmount = totalExpired[_token] + sumExpired;

        //Required reward token must be transferred before set process for previous user fund's protection
        require(IERC20(_token).balanceOf(address(this)) >= totalRewardAmount + totalExpiredAmount, "TD: not enough balance");

        totalRewardToClaim[_token] = totalRewardAmount;
        totalExpired[_token] = totalExpiredAmount;
    }

    /// @notice claim all rewards
    /// @param _rewardOwner address of reward owner 
    /// @param _recipient addres of recepient
    /// @return (tokens,amounts) array of reward tokens , array of claimed amount
    function claimAll(
        address _rewardOwner,
        address _recipient     
    ) external  returns (address[] memory,uint256[] memory) {
        uint256 length = allRewardTokens.length;

        address[] memory tokens = new address[](length);
        uint256[] memory amounts = new uint256[](length);

        for (uint256 i; i < length; i++) {
            address token = allRewardTokens[i];
            tokens[i] = token;
            amounts[i] = claim(token, _rewardOwner, _recipient);
        }
        return (tokens,amounts);
    }

    /// @notice claims rewards
    /// @dev only callable by owner or executor
    /// @param _token address of token
    /// @param _rewardOwner address of reward owner 
    /// @param _recipient addres of recepient
    /// @return claimedAmount claimed amount sent to the user
    function claim(
        address _token,
        address _rewardOwner,
        address _recipient        
    ) public
    nonReentrant 
    onlyOwnerOrExecutor(_rewardOwner, _recipient)
    returns (uint256) {
        require(rewardTokens[_token], "TD: invalid _token");
        AccountStatus memory status = accountStatus[_rewardOwner][_token];
        uint256 claimableAmount;
        if(status.lastIndex > 0 && status.processedIndex < status.lastIndex){
            uint256 currentDay = (block.timestamp / 1 days) * 1 days;
            uint256 sumExpired;

            uint256 firstIndex = status.processedIndex + 1;
            uint256 lastIndex = status.lastIndex;
            for(uint256 j = firstIndex; j <= lastIndex; j++) {
                Reward memory reward = rewards[_rewardOwner][_token][j];
                if(reward.timestamp + bufferTime < currentDay ){
                    unchecked {
                        sumExpired += reward.amount;
                    }
                    reward.status = RewardStatus.EXPIRED;
                    status.processedIndex = j.toUint128();    
                    emit ExpiredClaim(_rewardOwner, _token, reward.amount, reward.timestamp);
                }else{
                    unchecked {                        
                        claimableAmount += reward.amount;
                    }
                    reward.status = RewardStatus.CLAIMED;                    
                    emit HasClaimedWithTimestamp(_rewardOwner, _token, reward.amount, reward.timestamp);

                }
                reward.processTimestamp = block.timestamp.toUint48();
                rewards[_rewardOwner][_token][j] = reward;
            }  
            status.processedIndex = lastIndex.toUint128();
            accountStatus[_rewardOwner][_token] = status;
            if(sumExpired > 0){
                totalExpired[_token] += sumExpired;
            }
            if(sumExpired + claimableAmount > 0){
                totalRewardToClaim[_token] -= (sumExpired + claimableAmount);
            }
            if(claimableAmount > 0){
                IERC20(_token).safeTransfer(_recipient, claimableAmount);
            }
            emit HasClaimed(_rewardOwner, _recipient, _token, claimableAmount);
        }
        
        return claimableAmount;

    }

    /// @notice gets all claimable amount
    /// @param _account address of reward owner
    /// @return rewardTokens array of reward tokens
    /// @return claimableAmounts array of claimable amounts
    function claimableAll(address _account) external view returns (address[] memory,uint256[] memory) {
        uint256 length = allRewardTokens.length;

        address[] memory tokens = new address[](length);
        uint256[] memory amounts = new uint256[](length);

        for (uint256 i; i < length; i++) {
            address token = allRewardTokens[i];
            tokens[i] = token;
            amounts[i] = _claimable(token, _account);
        }
        return (tokens,amounts);
    }

    /// @notice gets claimable amount
    /// @param _token address of token
    /// @param _account address of reward owner
    /// @return claimableAmount claimable amounts
    function claimable(address _token, address _account) external view returns (uint256) {
        return _claimable(_token, _account);
    }

    /// @notice internal function of claimable function
    /// @param _token address of token
    /// @param _recipient address of reward owner
    /// @return claimableAmount claimable amounts
    function _claimable(address _token, address _recipient) private view returns (uint256) {
        require(rewardTokens[_token], "TD: invalid _token");
        uint256 claimableAmount;
        AccountStatus memory status = accountStatus[_recipient][_token];
        uint256 currentDay = (block.timestamp / 1 days) * 1 days;

        for(uint256 j = status.processedIndex + 1 ; j <= status.lastIndex; j++) {
            Reward memory reward = rewards[_recipient][_token][j];
            if(reward.timestamp + bufferTime >= currentDay ){
                unchecked {                        
                    claimableAmount += reward.amount;
                }
            }
        }    
        return claimableAmount;
    }

    /// @notice calls function on behalf of this contract
    /// @dev For flare airdrop and ftso delegation rewards  
    /// @dev Not allowed to call reward token contracts except batchDelegate function
    /// @dev reverted if reward tokens balance decreased after transaction
    /// @param target address of contract
    /// @param data tx data
    function functionCall(
        address target,
        bytes calldata data
    )
        external
        onlyOwner
    {
        require(target != address(0),"!target is empty");
        uint256 tokenLength = allRewardTokens.length;
        uint256[] memory beforeBalances = new uint256[](tokenLength);
        for (uint256 i; i <tokenLength; i++) {
            beforeBalances[i] = IERC20(allRewardTokens[i]).balanceOf(address(this));
        }

        bytes4 functionSel = bytes4(data[:4]);

        if(functionSel != 0xdc4fcda7 )  // ignore batchDelegate function For FTSO Provider Delegation
            for (uint256 i; i < tokenLength ; i++) {
                if(target == allRewardTokens[i]){
                    revert("!token address not allowed");
                }
                
            }      

        Address.functionCall(target, data);

        for (uint256 i; i < tokenLength; i++) {
            uint256 afterBalance = IERC20(allRewardTokens[i]).balanceOf(address(this));

            if(beforeBalances[i] > afterBalance){
                revert("!token balance decreased");
            }
        }        
    }

}



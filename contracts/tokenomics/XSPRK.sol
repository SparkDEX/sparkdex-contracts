// SPDX-License-Identifier: BSD-3-Clause
pragma solidity ^0.7.5;

import "./lib/Ownable2Step.sol";
import "./lib/SafeMath.sol";
import "./lib/SafeERC20.sol";
import "./lib/ERC20.sol";
import "./lib/ReentrancyGuard.sol";
import "./lib/EnumerableSet.sol";

import "./interfaces/IXSPRK.sol";
import "./interfaces/IXSPRKToken.sol";
import "./interfaces/IXSPRKTokenUsage.sol";

/*
 * xSPRK is SparkDEX escrowed  token obtainable by converting SPRK to it
 * It's non-transferable, except from/to whitelisted addresses
 * It can be converted back to SPRK through a vesting process
 * This contract is made to receive xSPRK deposits from users in order to allocate them to Usages (plugins) contracts
 */
contract XSPRKToken is Ownable2Step, ReentrancyGuard, ERC20("SparkDEX escrowed token", "xSPRK"), IXSPRKToken {
    using Address for address;
    using SafeMath for uint256;
    using EnumerableSet for EnumerableSet.AddressSet;
    using SafeERC20 for IXSPRK;

    struct XSPRKBalance {
        uint256 allocatedAmount; // Amount of xSPRK allocated to a Usage
        uint256 redeemingAmount; // Total amount of xSPRK currently being redeemed
    }

    struct RedeemInfo {
        uint256 sprkAmount; // SPRK amount to receive when vesting has ended
        uint256 xSPRKAmount; // xSPRK amount to redeem
        uint256 endTime;
        IXSPRKTokenUsage dividendsAddress;
        uint256 dividendsAllocation; // Share of redeeming xSPRK to allocate to the Dividends Usage contract
    }

    IXSPRK public immutable sprkToken; // SPRK token to convert to/from
    IXSPRKTokenUsage public dividendsAddress; // SparkDex dividends contract

    EnumerableSet.AddressSet private _transferWhitelist; // addresses allowed to send/receive xSPRK

    mapping(address => mapping(address => uint256)) public usageApprovals; // Usage approvals to allocate xSPRK
    mapping(address => mapping(address => uint256)) public override usageAllocations; // Active xSPRK allocations to usages

    uint256 public constant MAX_DEALLOCATION_FEE = 200; // 2%
    mapping(address => uint256) public usagesDeallocationFee; // Fee paid when deallocating xSPRK
    mapping(address => bool) public waitingUsersForRedeem; // wait until this time for special users (team allocation)

    uint256 public constant MAX_FIXED_RATIO = 100; // 100%
    address public constant BURN_ADDRESS = 0x000000000000000000000000000000000000dEaD;
    uint256 public constant TIMELOCK_BUFFER = 1 days;
    uint256 public constant TIMELOCK_MAX_DURATION = 7 days;

    // Redeeming min/max settings
    uint256 public minRedeemRatio = 50; // 1:0.5
    uint256 public maxRedeemRatio = 100; // 1:1
    uint256 public minRedeemDuration = 15 days; // 1296000s
    uint256 public maxRedeemDuration = 180 days; // 15552000s
    // Adjusted dividends rewards for redeeming xSPRK
    uint256 public redeemDividendsAdjustment = 50; // 50%
    uint256 public immutable redeemTimeForTeam;

    mapping(address => XSPRKBalance) public xSPRKBalances; // User's xSPRK balances
    mapping(address => RedeemInfo[]) public userRedeems; // User's redeeming instances
    struct PendingAction {
        uint256 timestamp; // timestamp
        bytes32 parametersKey; // parameters keccak 
    }
    mapping (bytes32 => PendingAction) public pendingActions;

    constructor(address sprkToken_, uint256 _redeemTimeForTeam, address owner_) Ownable(owner_) {
        require(_redeemTimeForTeam > block.timestamp,"invalid redeem time");
        require(sprkToken_ != address(0), "zero address");
        sprkToken = IXSPRK(sprkToken_);
        _transferWhitelist.add(address(this));
        redeemTimeForTeam = _redeemTimeForTeam;
    }

    /********************************************/
    /****************** EVENTS ******************/
    /********************************************/

    event ApproveUsage(address indexed userAddress, address indexed usageAddress, uint256 amount);
    event Convert(address indexed from, address to, uint256 amount);
    event UpdateRedeemSettings(uint256 minRedeemRatio, uint256 maxRedeemRatio, uint256 minRedeemDuration, uint256 maxRedeemDuration, uint256 redeemDividendsAdjustment);
    event UpdateDividendsAddress(address previousDividendsAddress, address newDividendsAddress);
    event UpdateDeallocationFee(address indexed usageAddress, uint256 fee);
    event SetTransferWhitelist(address account, bool add);
    event Redeem(address indexed userAddress, uint256 xSPRKAmount, uint256 sprkAmount, uint256 duration);
    event FinalizeRedeem(address indexed userAddress, uint256 xSPRKAmount, uint256 sprkAmount);
    event CancelRedeem(address indexed userAddress, uint256 xSPRKAmount);
    event UpdateRedeemDividendsAddress(address indexed userAddress, uint256 redeemIndex, address previousDividendsAddress, address newDividendsAddress);
    event Allocate(address indexed userAddress, address indexed usageAddress, uint256 amount);
    event Deallocate(address indexed userAddress, address indexed usageAddress, uint256 amount, uint256 fee);
    event WaitingUsersForRedeemSet(address indexed userAddress);
    event SignalPendingAction(bytes32 action, bytes32 parametersKey);
    event ClearAction(bytes32 action);
    event SignalSetWaitingUsersForRedeem(address user, bytes32 action);
    event SignalUpdateRedeemSettings(uint256 minRedeemRatio_,
        uint256 maxRedeemRatio_,
        uint256 minRedeemDuration_,
        uint256 maxRedeemDuration_,
        uint256 redeemDividendsAdjustment_, bytes32 action);
    event SignalUpdateDeallocationFee(address usageAddress, uint256 fee, bytes32 action);

    /***********************************************/
    /****************** MODIFIERS ******************/
    /***********************************************/

    /*
     * @dev Check if a redeem entry exists
     */
    modifier validateRedeem(address userAddress, uint256 redeemIndex) {
        require(redeemIndex < userRedeems[userAddress].length, "validateRedeem: redeem entry does not exist");
        _;
    }

    /**************************************************/
    /****************** PUBLIC VIEWS ******************/
    /**************************************************/

    /*
     * @dev Returns user's xSPRK balances
     */
    function getXSPRKBalance(address userAddress) external view returns (uint256 allocatedAmount, uint256 redeemingAmount) {
        XSPRKBalance storage balance = xSPRKBalances[userAddress];
        return (balance.allocatedAmount, balance.redeemingAmount);
    }

    /*
     * @dev returns redeemable SPRK for "amount" of xSPRK vested for "duration" seconds
     */
    function getSprkByVestingDuration(uint256 amount, uint256 duration) public view returns (uint256) {
        if (duration < minRedeemDuration) {
            return 0;
        }

        // capped to maxRedeemDuration
        if (duration > maxRedeemDuration) {
            return amount.mul(maxRedeemRatio).div(100);
        }

        uint256 ratio = minRedeemRatio.add((duration.sub(minRedeemDuration)).mul(maxRedeemRatio.sub(minRedeemRatio)).div(maxRedeemDuration.sub(minRedeemDuration)));

        return amount.mul(ratio).div(100);
    }

    /**
     * @dev returns quantity of "userAddress" pending redeems
     */
    function getUserRedeemsLength(address userAddress) external view returns (uint256) {
        return userRedeems[userAddress].length;
    }

    /**
     * @dev returns "userAddress" info for a pending redeem identified by "redeemIndex"
     */
    function getUserRedeem(
        address userAddress,
        uint256 redeemIndex
    )
        external
        view
        validateRedeem(userAddress, redeemIndex)
        returns (uint256 sprkAmount, uint256 xSPRKAmount, uint256 endTime, address dividendsContract, uint256 dividendsAllocation)
    {
        RedeemInfo storage _redeem = userRedeems[userAddress][redeemIndex];
        return (_redeem.sprkAmount, _redeem.xSPRKAmount, _redeem.endTime, address(_redeem.dividendsAddress), _redeem.dividendsAllocation);
    }

    /**
     * @dev returns approved xSPRK to allocate from "userAddress" to "usageAddress"
     */
    function getUsageApproval(address userAddress, address usageAddress) external view returns (uint256) {
        return usageApprovals[userAddress][usageAddress];
    }

    /**
     * @dev returns allocated xSPRK from "userAddress" to "usageAddress"
     */
    function getUsageAllocation(address userAddress, address usageAddress) external view returns (uint256) {
        return usageAllocations[userAddress][usageAddress];
    }

    /**
     * @dev returns length of transferWhitelist array
     */
    function transferWhitelistLength() external view returns (uint256) {
        return _transferWhitelist.length();
    }

    /**
     * @dev returns transferWhitelist array item's address for "index"
     */
    function transferWhitelist(uint256 index) external view returns (address) {
        return _transferWhitelist.at(index);
    }

    /**
     * @dev returns if "account" is allowed to send/receive xSPRK
     */
    function isTransferWhitelisted(address account) external view override returns (bool) {
        return _transferWhitelist.contains(account);
    }

    /*******************************************************/
    /****************** OWNABLE FUNCTIONS ******************/
    /*******************************************************/
    /**
    * @dev signal set users for redeem waiting list
    */
    function signalSetWaitingUsersForRedeem(address _user) external onlyOwner {
        bytes32 action = keccak256(abi.encodePacked("setWaitingUsersForRedeem", _user));
        _setPendingAction(action, bytes32(0));
        emit SignalSetWaitingUsersForRedeem(_user, action);
    }


    /**
    * @dev set users for redeem waiting list
    */
    function setWaitingUsersForRedeem(address _user) external onlyOwner {
        bytes32 action = keccak256(abi.encodePacked("setWaitingUsersForRedeem", _user));
        _validateAction(action, bytes32(0));
        _clearAction(action);        
        require(_user != address(0), "invalid user");
        waitingUsersForRedeem[_user] = true;
        emit WaitingUsersForRedeemSet(_user);
    }

    /**
     * @dev signal updates all redeem ratios and durations
     *
     * Must only be called by owner
     */
    function signalUpdateRedeemSettings(        
        uint256 minRedeemRatio_,
        uint256 maxRedeemRatio_,
        uint256 minRedeemDuration_,
        uint256 maxRedeemDuration_,
        uint256 redeemDividendsAdjustment_) external onlyOwner {
        bytes32 action = keccak256(abi.encodePacked("updateRedeemSettings"));
        bytes32 parametersKey = keccak256(abi.encodePacked(minRedeemRatio_,
        maxRedeemRatio_,
        minRedeemDuration_,
        maxRedeemDuration_,
        redeemDividendsAdjustment_));        
        _setPendingAction(action, parametersKey);
        emit SignalUpdateRedeemSettings(minRedeemRatio_,
        maxRedeemRatio_,
        minRedeemDuration_,
        maxRedeemDuration_,
        redeemDividendsAdjustment_, action);
    }


    /**
     * @dev Updates all redeem ratios and durations
     *
     * Must only be called by owner
     */
    function updateRedeemSettings(
        uint256 minRedeemRatio_,
        uint256 maxRedeemRatio_,
        uint256 minRedeemDuration_,
        uint256 maxRedeemDuration_,
        uint256 redeemDividendsAdjustment_
    ) external onlyOwner {
        bytes32 action = keccak256(abi.encodePacked("updateRedeemSettings"));
        bytes32 parametersKey = keccak256(abi.encodePacked(minRedeemRatio_,
        maxRedeemRatio_,
        minRedeemDuration_,
        maxRedeemDuration_,
        redeemDividendsAdjustment_));        
        _validateAction(action, parametersKey);
        _clearAction(action);      
        require(minRedeemRatio_ <= maxRedeemRatio_, "updateRedeemSettings: wrong ratio values");
        require(minRedeemDuration_ < maxRedeemDuration_, "updateRedeemSettings: wrong duration values");
        // should never exceed 100%
        require(maxRedeemRatio_ <= MAX_FIXED_RATIO && redeemDividendsAdjustment_ <= MAX_FIXED_RATIO, "updateRedeemSettings: wrong ratio values");

        minRedeemRatio = minRedeemRatio_;
        maxRedeemRatio = maxRedeemRatio_;
        minRedeemDuration = minRedeemDuration_;
        maxRedeemDuration = maxRedeemDuration_;
        redeemDividendsAdjustment = redeemDividendsAdjustment_;

        emit UpdateRedeemSettings(minRedeemRatio_, maxRedeemRatio_, minRedeemDuration_, maxRedeemDuration_, redeemDividendsAdjustment_);
    }

    /**
     * @dev Updates dividends contract address
     *
     * Must only be called by owner
     */
    function updateDividendsAddress(IXSPRKTokenUsage dividendsAddress_) external onlyOwner {
        // if set to 0, also set divs earnings while redeeming to 0
        if (address(dividendsAddress_) == address(0)) {
            redeemDividendsAdjustment = 0;
        }

        emit UpdateDividendsAddress(address(dividendsAddress), address(dividendsAddress_));
        dividendsAddress = dividendsAddress_;
    }
    /**
     * @dev signal updates fee paid by users when deallocating from "usageAddress"
     */
    function signalUpdateDeallocationFee(address usageAddress, uint256 fee) external onlyOwner {
        bytes32 action = keccak256(abi.encodePacked("updateDeallocationFee", usageAddress));
        bytes32 parametersKey = keccak256(abi.encodePacked(fee));         
        _setPendingAction(action, parametersKey);
        emit SignalUpdateDeallocationFee(usageAddress, fee, action);
    }

    /**
     * @dev Updates fee paid by users when deallocating from "usageAddress"
     */
    function updateDeallocationFee(address usageAddress, uint256 fee) external onlyOwner {
        bytes32 action = keccak256(abi.encodePacked("updateDeallocationFee", usageAddress));
        bytes32 parametersKey = keccak256(abi.encodePacked(fee));     
        _validateAction(action, parametersKey);
        _clearAction(action);              
        require(fee <= MAX_DEALLOCATION_FEE, "updateDeallocationFee: too high");

        usagesDeallocationFee[usageAddress] = fee;
        emit UpdateDeallocationFee(usageAddress, fee);
    }

    /**
     * @dev Adds or removes addresses from the transferWhitelist
     */
    function updateTransferWhitelist(address account, bool add) external onlyOwner {
        require(account != address(this), "updateTransferWhitelist: Cannot remove xSPRK from whitelist");

        if (add) _transferWhitelist.add(account);
        else _transferWhitelist.remove(account);

        emit SetTransferWhitelist(account, add);
    }

    /*****************************************************************/
    /******************  EXTERNAL PUBLIC FUNCTIONS  ******************/
    /*****************************************************************/

    /**
     * @dev Approves "usage" address to get allocations up to "amount" of xSPRK from msg.sender
     */
    function approveUsage(IXSPRKTokenUsage usage, uint256 amount) external nonReentrant {
        require(address(usage) != address(0), "approveUsage: approve to the zero address");

        usageApprovals[msg.sender][address(usage)] = amount;
        emit ApproveUsage(msg.sender, address(usage), amount);
    }

    /**
     * @dev Convert caller's "amount" of SPRK to xSPRK
     */
    function convert(uint256 amount) external nonReentrant {
        _convert(amount, msg.sender);
    }

    /**
     * @dev Convert caller's "amount" of SPRK to xSPRK to "to" address
     */
    function convertTo(uint256 amount, address to) external override nonReentrant {
        require(address(msg.sender).isContract(), "convertTo: not allowed");
        _convert(amount, to);
    }

    /**
     * @dev Initiates redeem process (xSPRK to SPRK)
     *
     * Handles dividends' compensation allocation during the vesting process if needed
     */
    function redeem(uint256 xSPRKAmount, uint256 duration) external nonReentrant {
        require(!waitingUsersForRedeem[msg.sender] || redeemTimeForTeam <= block.timestamp,"Redeem time has not come yet for team");
        require(xSPRKAmount > 0, "redeem: xSPRKAmount cannot be null");
        require(duration >= minRedeemDuration, "redeem: duration too low");
        require(duration < maxRedeemDuration * 2, "redeem: duration too high"); // to prevent excessively large duration values.

        _transfer(msg.sender, address(this), xSPRKAmount);
        XSPRKBalance storage balance = xSPRKBalances[msg.sender];

        // get corresponding SPRK amount
        uint256 sprkAmount = getSprkByVestingDuration(xSPRKAmount, duration);
        emit Redeem(msg.sender, xSPRKAmount, sprkAmount, duration);

        // if redeeming is not immediate, go through vesting process
        if (duration > 0) {
            // add to SBT total
            balance.redeemingAmount = balance.redeemingAmount.add(xSPRKAmount);

            // handle dividends during the vesting process
            uint256 dividendsAllocation = xSPRKAmount.mul(redeemDividendsAdjustment).div(100);
            // only if compensation is active
            if (dividendsAllocation > 0) {
                // allocate to dividends
                dividendsAddress.allocate(msg.sender, dividendsAllocation, new bytes(0));
            }

            // add redeeming entry
            userRedeems[msg.sender].push(RedeemInfo(sprkAmount, xSPRKAmount, _currentBlockTimestamp().add(duration), dividendsAddress, dividendsAllocation));
        } else {
            // immediately redeem for SPRK
            _finalizeRedeem(msg.sender, xSPRKAmount, sprkAmount);
        }
    }

    /**
     * @dev Finalizes redeem process when vesting duration has been reached
     *
     * Can only be called by the redeem entry owner
     */
    function finalizeRedeem(uint256 redeemIndex) external nonReentrant validateRedeem(msg.sender, redeemIndex) {
        XSPRKBalance storage balance = xSPRKBalances[msg.sender];
        RedeemInfo storage _redeem = userRedeems[msg.sender][redeemIndex];
        require(_currentBlockTimestamp() >= _redeem.endTime, "finalizeRedeem: vesting duration has not ended yet");

        // remove from SBT total
        balance.redeemingAmount = balance.redeemingAmount.sub(_redeem.xSPRKAmount);
        _finalizeRedeem(msg.sender, _redeem.xSPRKAmount, _redeem.sprkAmount);

        // handle dividends compensation if any was active
        if (_redeem.dividendsAllocation > 0) {
            // deallocate from dividends
            IXSPRKTokenUsage(_redeem.dividendsAddress).deallocate(msg.sender, _redeem.dividendsAllocation, new bytes(0));
        }

        // remove redeem entry
        _deleteRedeemEntry(redeemIndex);
    }

    /**
     * @dev Updates dividends address for an existing active redeeming process
     *
     * Can only be called by the involved user
     * Should only be used if dividends contract was to be migrated
     */
    function updateRedeemDividendsAddress(uint256 redeemIndex) external nonReentrant validateRedeem(msg.sender, redeemIndex) {
        RedeemInfo storage _redeem = userRedeems[msg.sender][redeemIndex];

        // only if the active dividends contract is not the same anymore
        if (dividendsAddress != _redeem.dividendsAddress && address(dividendsAddress) != address(0)) {
            if (_redeem.dividendsAllocation > 0) {
                // deallocate from old dividends contract
                _redeem.dividendsAddress.deallocate(msg.sender, _redeem.dividendsAllocation, new bytes(0));
                // allocate to new used dividends contract
                dividendsAddress.allocate(msg.sender, _redeem.dividendsAllocation, new bytes(0));
            }

            emit UpdateRedeemDividendsAddress(msg.sender, redeemIndex, address(_redeem.dividendsAddress), address(dividendsAddress));
            _redeem.dividendsAddress = dividendsAddress;
        }
    }

    /**
     * @dev Cancels an ongoing redeem entry
     *
     * Can only be called by its owner
     */
    function cancelRedeem(uint256 redeemIndex) external nonReentrant validateRedeem(msg.sender, redeemIndex) {
        XSPRKBalance storage balance = xSPRKBalances[msg.sender];
        RedeemInfo storage _redeem = userRedeems[msg.sender][redeemIndex];

        // make redeeming xSPRK available again
        balance.redeemingAmount = balance.redeemingAmount.sub(_redeem.xSPRKAmount);
        _transfer(address(this), msg.sender, _redeem.xSPRKAmount);

        // handle dividends compensation if any was active
        if (_redeem.dividendsAllocation > 0) {
            // deallocate from dividends
            IXSPRKTokenUsage(_redeem.dividendsAddress).deallocate(msg.sender, _redeem.dividendsAllocation, new bytes(0));
        }

        emit CancelRedeem(msg.sender, _redeem.xSPRKAmount);

        // remove redeem entry
        _deleteRedeemEntry(redeemIndex);
    }

    /**
     * @dev Allocates caller's "amount" of available xSPRK to "usageAddress" contract
     *
     * args specific to usage contract must be passed into "usageData"
     */
    function allocate(address usageAddress, uint256 amount, bytes calldata usageData) external nonReentrant {
        _allocate(msg.sender, usageAddress, amount);

        // allocates xSPRK to usageContract
        IXSPRKTokenUsage(usageAddress).allocate(msg.sender, amount, usageData);
    }

    /**
     * @dev Allocates "amount" of available xSPRK from "userAddress" to caller (ie usage contract)
     *
     * Caller must have an allocation approval for the required xSPRK xSPRK from "userAddress"
     */
    function allocateFromUsage(address userAddress, uint256 amount) external override nonReentrant {
        _allocate(userAddress, msg.sender, amount);
    }

    /**
     * @dev Deallocates caller's "amount" of available xSPRK from "usageAddress" contract
     *
     * args specific to usage contract must be passed into "usageData"
     */
    function deallocate(address usageAddress, uint256 amount, bytes calldata usageData) external nonReentrant {
        _deallocate(msg.sender, usageAddress, amount);

        // deallocate xSPRK into usageContract
        IXSPRKTokenUsage(usageAddress).deallocate(msg.sender, amount, usageData);
    }

    /**
     * @dev Deallocates "amount" of allocated xSPRK belonging to "userAddress" from caller (ie usage contract)
     *
     * Caller can only deallocate xSPRK from itself
     */
    function deallocateFromUsage(address userAddress, uint256 amount) external override nonReentrant {
        _deallocate(userAddress, msg.sender, amount);
    }

    /********************************************************/
    /****************** INTERNAL FUNCTIONS ******************/
    /********************************************************/

    /**
     * @dev Convert caller's "amount" of SPRK into xSPRK to "to"
     */
    function _convert(uint256 amount, address to) internal {
        require(amount != 0, "convert: amount cannot be null");

        // mint new xSPRK
        _mint(to, amount);

        emit Convert(msg.sender, to, amount);
        sprkToken.safeTransferFrom(msg.sender, address(this), amount);
    }

    /**
     * @dev Finalizes the redeeming process for "userAddress" by transferring him "sprkAmount" and removing "xSPRKAmount" from supply
     *
     * Any vesting check should be ran before calling this
     * SPRK excess is automatically burnt
     */
    function _finalizeRedeem(address userAddress, uint256 xSPRKAmount, uint256 sprkAmount) internal {
        uint256 sprkExcess = xSPRKAmount.sub(sprkAmount);

        // sends due SPRK tokens
        sprkToken.safeTransfer(userAddress, sprkAmount);

        // burns SPRK excess if any
        sprkToken.safeTransfer(BURN_ADDRESS, sprkExcess);
        _burn(address(this), xSPRKAmount);

        emit FinalizeRedeem(userAddress, xSPRKAmount, sprkAmount);
    }

    /**
     * @dev Allocates "userAddress" user's "amount" of available xSPRK to "usageAddress" contract
     *
     */
    function _allocate(address userAddress, address usageAddress, uint256 amount) internal {
        require(amount > 0, "allocate: amount cannot be null");

        XSPRKBalance storage balance = xSPRKBalances[userAddress];

        // approval checks if allocation request amount has been approved by userAddress to be allocated to this usageAddress
        uint256 approvedXSPRK = usageApprovals[userAddress][usageAddress];
        require(approvedXSPRK >= amount, "allocate: non authorized amount");

        // remove allocated amount from usage's approved amount
        usageApprovals[userAddress][usageAddress] = approvedXSPRK.sub(amount);

        // update usage's allocatedAmount for userAddress
        usageAllocations[userAddress][usageAddress] = usageAllocations[userAddress][usageAddress].add(amount);

        // adjust user's xSPRK balances
        balance.allocatedAmount = balance.allocatedAmount.add(amount);
        _transfer(userAddress, address(this), amount);

        emit Allocate(userAddress, usageAddress, amount);
    }

    /**
     * @dev Deallocates "amount" of available xSPRK to "usageAddress" contract
     *
     * args specific to usage contract must be passed into "usageData"
     */
    function _deallocate(address userAddress, address usageAddress, uint256 amount) internal {
        require(amount > 0, "deallocate: amount cannot be null");

        // check if there is enough allocated xSPRK to this usage to deallocate
        uint256 allocatedAmount = usageAllocations[userAddress][usageAddress];
        require(allocatedAmount >= amount, "deallocate: non authorized amount");

        // remove deallocated amount from usage's allocation
        usageAllocations[userAddress][usageAddress] = allocatedAmount.sub(amount);

        uint256 deallocationFeeAmount = amount.mul(usagesDeallocationFee[usageAddress]).div(10000);

        // adjust user's xSPRK balances
        XSPRKBalance storage balance = xSPRKBalances[userAddress];
        balance.allocatedAmount = balance.allocatedAmount.sub(amount);
        _transfer(address(this), userAddress, amount.sub(deallocationFeeAmount));
        // burn corresponding SPRK and XSPRK
        sprkToken.safeTransfer(BURN_ADDRESS, deallocationFeeAmount);
        _burn(address(this), deallocationFeeAmount);

        emit Deallocate(userAddress, usageAddress, amount, deallocationFeeAmount);
    }

    function _deleteRedeemEntry(uint256 index) internal {
        userRedeems[msg.sender][index] = userRedeems[msg.sender][userRedeems[msg.sender].length - 1];
        userRedeems[msg.sender].pop();
    }

    /**
     * @dev Hook override to forbid transfers except from whitelisted addresses and minting
     */
    function _beforeTokenTransfer(address from, address to, uint256 /*amount*/) internal view override {
        require(from == address(0) || _transferWhitelist.contains(from) || _transferWhitelist.contains(to), "transfer: not allowed");
    }

    /**
     * @dev Utility function to get the current block timestamp
     */
    function _currentBlockTimestamp() internal view virtual returns (uint256) {
        /* solhint-disable not-rely-on-time */
        return block.timestamp;
    }

    function cancelAction(bytes32 _action) external onlyOwner {
        _clearAction(_action);
    }

    function _setPendingAction(bytes32 _action, bytes32 _parametersKey) private {
        require(pendingActions[_action].timestamp == 0, "action already signalled");
        pendingActions[_action].timestamp = block.timestamp + TIMELOCK_BUFFER;
        pendingActions[_action].parametersKey = _parametersKey;
        emit SignalPendingAction(_action, _parametersKey);
    }

    function _validateAction(bytes32 _action, bytes32 _parametersKey) private view {
        PendingAction memory pendingAction = pendingActions[_action];
        require(pendingAction.timestamp != 0, "action not signalled");
        require(pendingAction.timestamp < block.timestamp, "action time not yet passed");
        require(pendingAction.parametersKey == _parametersKey, "params different from signal");    
        require(pendingAction.timestamp + TIMELOCK_MAX_DURATION > block.timestamp, "action expired");
    }

    function _clearAction(bytes32 _action) private {
        require(pendingActions[_action].timestamp != 0, "invalid _action");
        delete pendingActions[_action];
        emit ClearAction(_action);
    }

}

// SPDX-License-Identifier: MIT

pragma solidity ^0.8.20;

// Chainlink
import {VRFCoordinatorV2Interface} from "@chainlink/contracts/src/v0.8/interfaces/VRFCoordinatorV2Interface.sol";
import {VRFConsumerBaseV2} from "@chainlink/contracts/src/v0.8/VRFConsumerBaseV2.sol";

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";

contract TokenRumble is VRFConsumerBaseV2, AccessControl {
    ///////////////////
    // Type declarations
    ///////////////////

    struct Rumble {
        uint256 rewardAmount;
        uint256 entryFee;
        address[] participants;
        address winner;
        bool closed;
        uint64 maxNumOfParticipants;
        uint64 duration;
        uint64 startTime;
    }

    struct RumbleConfig {
        address vrfCoordinator;
        address priceFeed;
        bytes32 gasLane;
        uint64 subscriptionId;
        uint32 callbackGasLimit;
    }

    struct ChainlinkVRFConfig {
        uint16 requestConfirmations;
        uint32 numWords;
        VRFCoordinatorV2Interface vrfCoordinator;
        bytes32 gasLane;
        uint64 subscriptionId;
        uint32 callbackGasLimit;
    }

    ///////////////////
    // State variables
    ///////////////////

    // Chainlink VRF
    ChainlinkVRFConfig private s_vrfConfig;

    // Rumbles
    uint256 public s_rumbleCount;
    mapping(uint256 rumbleId => Rumble rumble) private s_rumbleAtId;
    mapping(uint256 requestId => uint256 rumbleId)
        private s_rumbleIdAtRequestId;
    mapping(uint256 rumbleId => uint256 activeRumbleIndex)
        private s_activeRumbleIndexAtId;
    uint256[] private s_activeRumbleIds;
    uint256[] private s_closedRumbleIds;
    address[] private s_winners;

    ///////////////////
    // Events
    ///////////////////

    event RumbleCreated(
        uint256 rumbleId,
        uint256 rewardAmount,
        uint256 entryFee,
        uint64 maxNumOfParticipants,
        uint64 duration,
        uint64 startTime
    );
    event RumbleEntered(
        uint256 rumbleId,
        address participant,
        uint256 entryFee
    );
    event RumbleClosed(uint256 rumbleId, address winner);

    ///////////////////
    // Errors
    ///////////////////

    error TokenRumble__NotEnoughValueSent();
    error TokenRumble__IncorrectRumbleData();
    error TokenRumble__RumbleClosed();
    error TokenRumble__MaxNumOfParticipantsReached();
    error TokenRumble__TransferToWinnerFailed();
    error TokenRumble__RumbleNotFound();
    error TokenRumble__RumbleStillRunning();

    ///////////////////
    // Functions
    ///////////////////

    modifier RumbleExists(uint256 _rumbleId) {
        if (_rumbleId > s_rumbleCount || _rumbleId == 0) {
            revert TokenRumble__RumbleNotFound();
        }
        _;
    }

    modifier RumbleNotClosed(uint256 _rumbleId) {
        if (s_rumbleAtId[_rumbleId].closed) {
            revert TokenRumble__RumbleClosed();
        }
        _;
    }

    constructor(
        RumbleConfig memory config
    ) VRFConsumerBaseV2(config.vrfCoordinator) {
        s_vrfConfig = ChainlinkVRFConfig({
            requestConfirmations: 3,
            numWords: 1,
            vrfCoordinator: VRFCoordinatorV2Interface(config.vrfCoordinator),
            gasLane: config.gasLane,
            subscriptionId: config.subscriptionId,
            callbackGasLimit: config.callbackGasLimit
        });
    }

    ////////////////////
    // External / Public
    ////////////////////

    /**
     * @param _rewardAmount The amount of tokens to be rewarded to the winner (in wei)
     * @param _maxNumOfParticipants The maximum number of participants allowed in the rumble
     * @param _duration The duration of the rumble in seconds
     */
    function createRumble(
        uint256 _rewardAmount,
        uint64 _maxNumOfParticipants,
        uint64 _duration
    ) external {
        if (
            _rewardAmount < _maxNumOfParticipants ||
            _rewardAmount <= 0 ||
            _maxNumOfParticipants <= 0 ||
            _duration <= 0
        ) {
            revert TokenRumble__IncorrectRumbleData();
        }

        Rumble memory rumble = Rumble({
            rewardAmount: _rewardAmount,
            entryFee: _rewardAmount / _maxNumOfParticipants,
            maxNumOfParticipants: _maxNumOfParticipants,
            participants: new address[](0),
            winner: address(0),
            duration: _duration,
            startTime: uint64(block.timestamp),
            closed: false
        });

        s_rumbleAtId[++s_rumbleCount] = rumble;
        s_activeRumbleIndexAtId[s_rumbleCount] = s_activeRumbleIds.length;
        s_activeRumbleIds.push(s_rumbleCount);

        emit RumbleCreated(
            s_rumbleCount,
            rumble.rewardAmount,
            rumble.entryFee,
            rumble.maxNumOfParticipants,
            rumble.duration,
            rumble.startTime
        );
    }

    function enterRumbleETH(
        uint256 _rumbleId
    ) external payable RumbleExists(_rumbleId) RumbleNotClosed(_rumbleId) {
        Rumble storage rumble = s_rumbleAtId[_rumbleId];
        if (msg.value < rumble.entryFee) {
            revert TokenRumble__NotEnoughValueSent();
        }
        if (rumble.participants.length + 1 <= rumble.maxNumOfParticipants) {
            rumble.participants.push(msg.sender);
            emit RumbleEntered(_rumbleId, msg.sender, rumble.entryFee);
            if (rumble.participants.length == rumble.maxNumOfParticipants) {
                _closeRumble(_rumbleId);
                _drawWinner(_rumbleId);
            }
        }
    }

    function closeRumble(
        uint256 _rumbleId
    ) external RumbleExists(_rumbleId) RumbleNotClosed(_rumbleId) {
        Rumble storage rumble = s_rumbleAtId[_rumbleId];

        if (rumble.startTime + rumble.duration > block.timestamp) {
            revert TokenRumble__RumbleStillRunning();
        }

        // If Rumble not full, recompute reward amount
        rumble.rewardAmount = rumble.entryFee * rumble.participants.length;

        _closeRumble(_rumbleId);
        _drawWinner(_rumbleId);
    }

    function _closeRumble(uint256 _rumbleId) internal {
        Rumble storage rumble = s_rumbleAtId[_rumbleId];
        rumble.closed = true;
        uint256 rumbleIndex = s_activeRumbleIndexAtId[_rumbleId];
        uint256 lastIndex = s_activeRumbleIds.length - 1;

        if (rumbleIndex != lastIndex) {
            uint256 lastRumbleId = s_activeRumbleIds[lastIndex];
            s_activeRumbleIds[rumbleIndex] = lastRumbleId;
            s_activeRumbleIndexAtId[lastRumbleId] = rumbleIndex;
        }

        s_activeRumbleIds.pop();
        delete s_activeRumbleIndexAtId[_rumbleId];
        s_closedRumbleIds.push(_rumbleId);
    }

    function _drawWinner(uint256 _rumbleId) internal {
        uint256 requestId = s_vrfConfig.vrfCoordinator.requestRandomWords(
            s_vrfConfig.gasLane,
            s_vrfConfig.subscriptionId,
            s_vrfConfig.requestConfirmations,
            s_vrfConfig.callbackGasLimit,
            s_vrfConfig.numWords
        );
        s_rumbleIdAtRequestId[requestId] = _rumbleId;
    }

    function fulfillRandomWords(
        uint256 requestId,
        uint256[] memory randomWords
    ) internal override {
        uint256 _rumbleId = s_rumbleIdAtRequestId[requestId];
        Rumble storage rumble = s_rumbleAtId[_rumbleId];
        uint256 winnerIndex = randomWords[0] % rumble.participants.length;
        address winner = rumble.participants[winnerIndex];
        rumble.winner = winner;
        s_winners.push(winner);
        (bool success, ) = winner.call{value: rumble.rewardAmount}("");
        if (!success) {
            revert TokenRumble__TransferToWinnerFailed();
        }
        emit RumbleClosed(_rumbleId, winner);
    }

    ////////////////////
    // External View / Getters
    ////////////////////

    function getRumble(
        uint256 _rumbleId
    ) external view returns (Rumble memory rumble) {
        return s_rumbleAtId[_rumbleId];
    }

    function getRumbleEntryFee(
        uint256 _rumbleId
    ) external view returns (uint256 entryFee) {
        return s_rumbleAtId[_rumbleId].entryFee;
    }

    function getRumbleRewardAmount(
        uint256 _rumbleId
    ) external view returns (uint256 rewardAmount) {
        return s_rumbleAtId[_rumbleId].rewardAmount;
    }

    function getRumbleMaxNumOfParticipants(
        uint256 _rumbleId
    ) external view returns (uint64 maxNumOfParticipants) {
        return s_rumbleAtId[_rumbleId].maxNumOfParticipants;
    }

    function getRumbleDuration(
        uint256 _rumbleId
    ) external view returns (uint64 duration) {
        return s_rumbleAtId[_rumbleId].duration;
    }

    function getRumbleStartTime(
        uint256 _rumbleId
    ) external view returns (uint64 startTime) {
        return s_rumbleAtId[_rumbleId].startTime;
    }

    function getRumbleParticipants(
        uint256 _rumbleId
    ) external view returns (address[] memory participants) {
        return s_rumbleAtId[_rumbleId].participants;
    }

    function getRumbleWinner(
        uint256 _rumbleId
    ) external view returns (address winner) {
        return s_rumbleAtId[_rumbleId].winner;
    }

    function getActiveRumbleIds() external view returns (uint256[] memory) {
        return s_activeRumbleIds;
    }

    function getClosedRumbleIds() external view returns (uint256[] memory) {
        return s_closedRumbleIds;
    }

    function getWinners() external view returns (address[] memory) {
        return s_winners;
    }
}

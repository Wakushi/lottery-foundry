// SPDX-License-Identifier: MIT

pragma solidity ^0.8.19;

import {VRFCoordinatorV2Interface} from "@chainlink/contracts/src/v0.8/interfaces/VRFCoordinatorV2Interface.sol";
import {VRFConsumerBaseV2} from "@chainlink/contracts/src/v0.8/VRFConsumerBaseV2.sol";
import {AggregatorV3Interface} from "@chainlink/contracts/src/v0.8/interfaces/AggregatorV3Interface.sol";
import {AutomationCompatibleInterface} from "@chainlink/contracts/src/v0.8/interfaces/AutomationCompatibleInterface.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {PriceConverter} from "./PriceConverter.sol";

contract Lottery is VRFConsumerBaseV2, AutomationCompatibleInterface, Ownable {
    ///////////////////
    // Type declarations
    ///////////////////

    enum LotteryState {
        OPEN,
        CALCULATING
    }

    using PriceConverter for uint256;

    struct ChainlinkVRFConfig {
        uint16 requestConfirmations;
        uint32 numWords;
        VRFCoordinatorV2Interface vrfCoordinator;
        bytes32 gasLane;
        uint64 subscriptionId;
        uint32 callbackGasLimit;
    }

    struct LotteryConfig {
        address vrfCoordinator;
        address priceFeed;
        bytes32 gasLane;
        uint64 subscriptionId;
        uint32 callbackGasLimit;
        uint32 interval;
    }

    ///////////////////
    // State variables
    ///////////////////

    // Chainlink VRF
    ChainlinkVRFConfig private vrfConfig;

    // Chainlink Data Feed
    AggregatorV3Interface private s_priceFeed;
    uint256 public constant TICKET_PRICE = 5 * 10 ** 18; // 5 USD

    // Lottery
    uint256 public constant TICKET_FEE_PERCENTAGE = 3; // 0.3%
    uint256 public constant MATCHES_AMOUNT_REQUIRED = 3;
    uint256 public constant GRID_NUMBERS_AMOUNT = 6;

    LotteryState public s_lotteryState;
    uint256 private immutable i_interval;
    uint256 public s_lastTimeStamp;
    address public s_lastWinner;
    uint256 public s_lastAmountWon;

    mapping(address player => uint256[] numbers) s_playersEntry;
    mapping(address player => bool entered) s_playersEntered;
    address payable[] s_players;
    uint256 s_totalPrizePool;
    uint256 s_totalFees;

    ///////////////////
    /// Events
    ///////////////////

    event EnteredLottery(address player, uint256[] numbers);
    event RequestedLotteryWinner(uint256 requestId);
    event PickedWinner(address winner);

    ///////////////////
    // Errors
    ///////////////////

    error Lottery__InvalidTicketPrice();
    error Lottery__InvalidAmountOfNumbers();
    error Lottery__InvalidNumbers();
    error Lottery__UpkeepNotNeeded(
        uint256 balance,
        uint256 playersLength,
        uint256 lotteryState
    );
    error Lottery__TransferFailed();
    error Lottery__LotteryNotOpen();
    error Lottery_AlreadyEntered();

    ///////////////////
    // Functions
    ///////////////////

    constructor(
        LotteryConfig memory config
    ) VRFConsumerBaseV2(config.vrfCoordinator) Ownable(msg.sender) {
        vrfConfig = ChainlinkVRFConfig({
            requestConfirmations: 3,
            numWords: 6,
            vrfCoordinator: VRFCoordinatorV2Interface(config.vrfCoordinator),
            gasLane: config.gasLane,
            subscriptionId: config.subscriptionId,
            callbackGasLimit: config.callbackGasLimit
        });
        s_priceFeed = AggregatorV3Interface(config.priceFeed);
        i_interval = config.interval;
    }

    receive() external payable {}

    fallback() external payable {}

    ////////////////////
    // External / Public
    ////////////////////

    function play(uint256[] calldata _numbers) external payable {
        uint256 ticketPriceInEth = TICKET_PRICE.getConversionRate(s_priceFeed);

        if (s_lotteryState == LotteryState.CALCULATING) {
            revert Lottery__LotteryNotOpen();
        }

        if (s_playersEntered[msg.sender]) {
            revert Lottery_AlreadyEntered();
        }

        if (msg.value < ticketPriceInEth) {
            revert Lottery__InvalidTicketPrice();
        }
        if (_numbers.length != 6) {
            revert Lottery__InvalidAmountOfNumbers();
        }
        for (uint256 i = 0; i < 6; ++i) {
            if (_numbers[i] < 1 || _numbers[i] > 50) {
                revert Lottery__InvalidNumbers();
            }
        }

        uint256 fees = (ticketPriceInEth * TICKET_FEE_PERCENTAGE) / 1000;
        s_totalPrizePool += ticketPriceInEth - fees;
        s_totalFees += fees;

        s_playersEntered[msg.sender] = true;
        s_playersEntry[msg.sender] = _numbers;
        s_players.push(payable(msg.sender));

        emit EnteredLottery(msg.sender, _numbers);
    }

    function checkUpkeep(
        bytes memory /* checkData */
    )
        public
        view
        override
        returns (bool upkeepNeeded, bytes memory /* performData */)
    {
        bool timeHasPassed = (block.timestamp - s_lastTimeStamp) >= i_interval;
        bool isOpen = s_lotteryState == LotteryState.OPEN;
        bool hasBalance = address(this).balance > 0;
        bool hasPlayers = s_players.length > 0;
        upkeepNeeded = (timeHasPassed && isOpen && hasBalance && hasPlayers);
        return (upkeepNeeded, "0x0");
    }

    function performUpkeep(bytes calldata /* performData */) external override {
        (bool upKeepNeeded, ) = checkUpkeep("");
        if (!upKeepNeeded) {
            revert Lottery__UpkeepNotNeeded(
                address(this).balance,
                s_players.length,
                uint256(s_lotteryState)
            );
        }
        s_lotteryState = LotteryState.CALCULATING;
        _drawNumbers();
    }

    function withdrawFees() external onlyOwner {
        (bool callSuccess, ) = msg.sender.call{value: s_totalFees}("");
        if (!callSuccess) {
            revert Lottery__TransferFailed();
        }
        s_totalFees = 0;
    }

    ////////////////////
    // Internal
    ////////////////////

    function _drawNumbers() internal {
        uint256 requestId = vrfConfig.vrfCoordinator.requestRandomWords(
            vrfConfig.gasLane,
            vrfConfig.subscriptionId,
            vrfConfig.requestConfirmations,
            vrfConfig.callbackGasLimit,
            vrfConfig.numWords
        );
        emit RequestedLotteryWinner(requestId);
    }

    function fulfillRandomWords(
        uint256 /*requestId*/,
        uint256[] memory randomWords
    ) internal override {
        uint256[] memory winningNumbers = new uint256[](GRID_NUMBERS_AMOUNT);
        for (uint256 i = 0; i < GRID_NUMBERS_AMOUNT; i++) {
            winningNumbers[i] = (randomWords[i] % 49) + 1;
        }
        _calculateWinners(winningNumbers);
    }

    function _calculateWinners(uint256[] memory _winningNumbers) internal {
        uint256[] memory winningNumbers = _winningNumbers;
        uint256[] memory winningPlayers = new uint256[](s_players.length);
        uint256 winningPlayersLength = 0;
        for (uint256 i = 0; i < s_players.length; ++i) {
            uint256[] memory playerNumbers = s_playersEntry[s_players[i]];
            uint256 matches = 0;
            for (uint256 j = 0; j < GRID_NUMBERS_AMOUNT; ++j) {
                for (uint256 k = 0; k < GRID_NUMBERS_AMOUNT; ++k) {
                    if (playerNumbers[j] == winningNumbers[k]) {
                        matches++;
                    }
                }
            }
            if (matches >= MATCHES_AMOUNT_REQUIRED) {
                winningPlayers[winningPlayersLength] = i;
                winningPlayersLength++;
            }
            s_playersEntered[s_players[i]] = false;
        }
        if (winningPlayersLength > 0) {
            uint256 totalAmountWon = s_totalPrizePool / winningPlayersLength;
            for (uint256 i = 0; i < winningPlayersLength; ++i) {
                address winner = s_players[winningPlayers[i]];
                emit PickedWinner(winner);
                (bool callSuccess, ) = winner.call{value: totalAmountWon}("");
                if (!callSuccess) {
                    revert Lottery__TransferFailed();
                }
            }
            s_lastWinner = s_players[winningPlayers[0]];
            s_lastAmountWon = totalAmountWon;
            s_totalPrizePool = 0;
            s_totalFees = 0;
        }
        s_lastTimeStamp = block.timestamp;
        for (uint256 i = 0; i < s_players.length; ++i) {
            delete s_playersEntry[s_players[i]];
        }
        delete s_players;
        s_lotteryState = LotteryState.OPEN;
    }

    ////////////////////
    // External View / Pure
    ////////////////////

    function getTicketPrice() external pure returns (uint256) {
        return TICKET_PRICE;
    }

    function getRaffleState() external view returns (LotteryState) {
        return s_lotteryState;
    }

    function getPlayer(uint256 indexOfPlayer) external view returns (address) {
        return s_players[indexOfPlayer];
    }

    function getLastWinner() external view returns (address) {
        return s_lastWinner;
    }

    function getLengthOfPlayers() external view returns (uint256) {
        return s_players.length;
    }

    function getLastTimeStamp() external view returns (uint256) {
        return s_lastTimeStamp;
    }
}

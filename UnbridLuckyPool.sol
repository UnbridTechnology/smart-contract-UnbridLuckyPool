// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

// Import SafeERC20 from OpenZeppelin
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";

contract UnbridLuckyPool {
    // Use SafeERC20 for all IERC20 interfaces
    using SafeERC20 for IERC20;

    // Structures
    struct Pool {
        uint256 id;
        bool isOpen;
        uint256 entryPrice;
        uint256 totalCollected;
        address[] participants;
        mapping(address => uint256) betsByParticipant;
        address winner;
        bool prizeDistributed;
        address tokenAddress;
        bytes32 creationHash; // <-- Hash único del pool
    }

    // State variables
    address public owner;
    address public VAULT_ACCOUNT;
    uint256 public winnerPercentage; // based on 100, example: 70 for 70%
    uint256 public vaultPercentage; // based on 100, example: 30 for 30%
    uint256 public poolCounter;
    mapping(uint256 => Pool) public pools;
    mapping(address => uint256) public totalEarningsByToken;
    mapping(uint256 => uint256) public poolCloseBlock; // Almacena el bloque en el que se cerró el pool
    // To prevent reentrancy attacks
    bool private locked;

    // Events
    event PoolCreated(
        uint256 indexed poolId,
        uint256 entryPrice,
        address tokenAddress
    );
    event PoolOpened(uint256 indexed poolId);
    event PoolClosed(uint256 indexed poolId);
    event BetPlaced(
        uint256 indexed poolId,
        address indexed bettor,
        uint256 amount
    );
    event WinnerSelected(uint256 indexed poolId, address indexed winner);
    event PrizeDistributed(
        uint256 indexed poolId,
        address indexed winner,
        uint256 winnerAmount,
        uint256 vaultAmount
    );
    event VaultAccountUpdated(address oldVault, address newVault);
    event PercentagesUpdated(uint256 winnerPercentage, uint256 vaultPercentage);
    event EarningsDeposited(
        address indexed depositor,
        address indexed tokenAddress,
        uint256 amount
    );
    event Withdrawn(address indexed to, address indexed token, uint256 amount);
    event PoolCreated(uint256 indexed poolId, bytes32 creationHash);
    // Modifiers
    modifier onlyOwner() {
        require(msg.sender == owner, "Only owner can execute this function");
        _;
    }

    modifier poolExists(uint256 _poolId) {
        require(_poolId < poolCounter, "Pool does not exist");
        _;
    }

    modifier poolIsOpen(uint256 _poolId) {
        require(pools[_poolId].isOpen, "Pool is not open");
        _;
    }

    modifier nonReentrant() {
        require(!locked, "Reentrant call");
        locked = true;
        _;
        locked = false;
    }

    // Constructor
    constructor(address _vaultAccount) {
        owner = msg.sender;
        VAULT_ACCOUNT = _vaultAccount;
        winnerPercentage = 70;
        vaultPercentage = 30;
        poolCounter = 0;
        locked = false;
    }

    // Contract management functions
    function setVaultAccount(address _newVaultAccount) external onlyOwner {
        address oldVault = VAULT_ACCOUNT;
        VAULT_ACCOUNT = _newVaultAccount;
        emit VaultAccountUpdated(oldVault, _newVaultAccount);
    }

    function setPercentages(uint256 _winnerPercentage, uint256 _vaultPercentage)
        external
        onlyOwner
    {
        require(
            _winnerPercentage + _vaultPercentage == 100,
            "Percentages must add up to 100"
        );
        winnerPercentage = _winnerPercentage;
        vaultPercentage = _vaultPercentage;
        emit PercentagesUpdated(_winnerPercentage, _vaultPercentage);
    }

    // Pool management functions
    function createPool(uint256 _entryPrice, address _tokenAddress)
        external
        onlyOwner
        returns (uint256)
    {
        uint256 poolId = poolCounter;
        Pool storage newPool = pools[poolId];

        // Generar hash único usando datos públicos e inmutables
        bytes32 hash = keccak256(
            abi.encodePacked(
                block.timestamp,
                block.prevrandao,
                poolId,
                _entryPrice,
                _tokenAddress
            )
        );

        newPool.id = poolId;
        newPool.isOpen = true;
        newPool.entryPrice = _entryPrice;
        newPool.totalCollected = 0;
        newPool.prizeDistributed = false;
        newPool.tokenAddress = _tokenAddress;
        newPool.creationHash = hash; // <-- Guardar el hash único

        poolCounter++;
        emit PoolCreated(poolId, _entryPrice, _tokenAddress);
        return poolId;
    }

    function openPool(uint256 _poolId) external onlyOwner poolExists(_poolId) {
        require(!pools[_poolId].isOpen, "Pool is already open");
        pools[_poolId].isOpen = true;
        emit PoolOpened(_poolId);
    }

    function closePool(uint256 _poolId) external onlyOwner poolExists(_poolId) {
        require(pools[_poolId].isOpen, "Pool is already closed");
        pools[_poolId].isOpen = false;
        poolCloseBlock[_poolId] = block.number; // Guardar el bloque en el que se cerró el pool
        emit PoolClosed(_poolId);
    }

    // Betting functions
    // For ETH bets
    function placeBet(uint256 _poolId, address user)
        external
        payable
        onlyOwner
        poolExists(_poolId)
        poolIsOpen(_poolId)
        nonReentrant
    {
        Pool storage pool = pools[_poolId];
        require(
            pool.tokenAddress == address(0),
            "This pool accepts only ERC-20 tokens"
        );
        require(
            msg.value == pool.entryPrice,
            "Sent amount must match entry price"
        );

        _recordBet(_poolId, user, msg.value);
    }

    // For ERC-20 token bets
    function placeBetWithToken(uint256 _poolId, address user)
        external
        onlyOwner
        poolExists(_poolId)
        poolIsOpen(_poolId)
        nonReentrant
    {
        Pool storage pool = pools[_poolId];
        require(pool.tokenAddress != address(0), "This pool accepts only ETH");

        IERC20 token = IERC20(pool.tokenAddress);
        uint256 entryPrice = pool.entryPrice;

        // Check if user has approved the contract to spend tokens
        require(
            token.allowance(user, address(this)) >= entryPrice,
            "Insufficient token allowance"
        );

        // Transfer tokens from user to contract using safeTransferFrom
        token.safeTransferFrom(user, address(this), entryPrice);

        _recordBet(_poolId, user, entryPrice);
    }

    // Internal function to record a bet
    function _recordBet(
        uint256 _poolId,
        address bettor,
        uint256 amount
    ) internal {
        Pool storage pool = pools[_poolId];

        // If this is the participant's first bet, add them to the array
        if (pool.betsByParticipant[bettor] == 0) {
            pool.participants.push(bettor);
        }

        // Update number of bets and total collected
        pool.betsByParticipant[bettor] += 1;
        pool.totalCollected += amount;

        emit BetPlaced(_poolId, bettor, amount);
    }

    // Function to withdraw funds
    /**
     * @dev Allows the owner to withdraw funds
     * @param to Address to withdraw to
     * @param amount Amount to withdraw
     * @param erc20Token ERC-20 token address (use address(0) for ETH)
     */
    function withdraw(
        address to,
        uint256 amount,
        address erc20Token
    ) external onlyOwner nonReentrant {
        require(to != address(0), "Cannot withdraw to zero address");
        require(amount > 0, "Amount must be greater than 0");

        if (erc20Token == address(0)) {
            // Withdraw ETH
            require(
                address(this).balance >= amount,
                "Insufficient ETH balance"
            );
            (bool success, ) = to.call{value: amount}("");
            require(success, "ETH withdrawal failed");
        } else {
            // Withdraw ERC-20 tokens
            IERC20 token = IERC20(erc20Token);
            require(
                token.balanceOf(address(this)) >= amount,
                "Insufficient token balance"
            );
            token.safeTransfer(to, amount);
        }

        emit Withdrawn(to, erc20Token, amount);
    }

    // Winner selection and prize distribution functions
    function selectWinner(uint256 _poolId)
        external
        onlyOwner
        poolExists(_poolId)
        nonReentrant
    {
        Pool storage pool = pools[_poolId];
        require(!pool.isOpen, "Pool must be closed");
        require(pool.winner == address(0), "Winner already selected");

        // Generar semilla usando datos inmutables del pool
        uint256 randomSeed = uint256(
            keccak256(
                abi.encodePacked(
                    pool.creationHash,
                    pool.participants.length, // Número de participantes
                    pool.totalCollected // Total recaudado
                )
            )
        );

        // Crear array con todas las entradas
        address[] memory allEntries = new address[](
            pool.totalCollected / pool.entryPrice
        );
        uint256 index = 0;

        for (uint256 i = 0; i < pool.participants.length; i++) {
            address participant = pool.participants[i];
            uint256 betCount = pool.betsByParticipant[participant];

            for (uint256 j = 0; j < betCount; j++) {
                allEntries[index] = participant;
                index++;
            }
        }

        // Seleccionar ganador
        uint256 randomIndex = randomSeed % allEntries.length;
        pool.winner = allEntries[randomIndex];

        emit WinnerSelected(_poolId, pool.winner);
    }

    function distributePrize(uint256 _poolId)
        external
        onlyOwner
        poolExists(_poolId)
        nonReentrant
    {
        Pool storage pool = pools[_poolId];
        require(!pool.isOpen, "Pool must be closed to distribute prize");
        require(pool.winner != address(0), "Winner has not been selected yet");
        require(!pool.prizeDistributed, "Prize has already been distributed");

        uint256 totalAmount = pool.totalCollected;
        uint256 winnerAmount = (totalAmount * winnerPercentage) / 100;
        uint256 vaultAmount = totalAmount - winnerAmount;

        pool.prizeDistributed = true;

        if (pool.tokenAddress == address(0)) {
            // ETH distribution
            (bool successWinner, ) = pool.winner.call{value: winnerAmount}("");
            require(successWinner, "Error sending ETH to winner");

            (bool successVault, ) = VAULT_ACCOUNT.call{value: vaultAmount}("");
            require(successVault, "Error sending ETH to vault");
        } else {
            // ERC-20 token distribution using safeTransfer
            IERC20 token = IERC20(pool.tokenAddress);
            token.safeTransfer(pool.winner, winnerAmount);
            token.safeTransfer(VAULT_ACCOUNT, vaultAmount);
        }

        emit PrizeDistributed(_poolId, pool.winner, winnerAmount, vaultAmount);
    }

    // Query functions
    function getPoolInfo(uint256 _poolId)
        external
        view
        poolExists(_poolId)
        returns (
            bool isOpen,
            uint256 entryPrice,
            uint256 totalCollected,
            uint256 participantsCount,
            address winner,
            bool prizeDistributed,
            address tokenAddress
        )
    {
        Pool storage pool = pools[_poolId];
        return (
            pool.isOpen,
            pool.entryPrice,
            pool.totalCollected,
            pool.participants.length,
            pool.winner,
            pool.prizeDistributed,
            pool.tokenAddress
        );
    }

    function getParticipantBets(uint256 _poolId, address _participant)
        external
        view
        poolExists(_poolId)
        returns (uint256)
    {
        return pools[_poolId].betsByParticipant[_participant];
    }

    function getParticipants(uint256 _poolId)
        external
        view
        poolExists(_poolId)
        returns (address[] memory)
    {
        return pools[_poolId].participants;
    }

    // Get token metadata (name, symbol, decimals)
    function getTokenMetadata(address tokenAddress)
        external
        view
        returns (
            string memory name,
            string memory symbol,
            uint8 decimals
        )
    {
        require(tokenAddress != address(0), "Not an ERC-20 token address");
        IERC20Metadata token = IERC20Metadata(tokenAddress);
        return (token.name(), token.symbol(), token.decimals());
    }

    // Handle different token decimals when needed
    function getScalingFactor(address tokenAddress)
        external
        view
        returns (uint256)
    {
        if (tokenAddress == address(0)) return 1; // ETH has 18 decimals, no scaling needed

        uint8 tokenDecimals = IERC20Metadata(tokenAddress).decimals();
        if (tokenDecimals == 18) return 1; // No scaling needed

        // Calculate scaling factor for non-standard decimal tokens
        return 10**(18 - tokenDecimals);
    }

    // Function to receive ETH
    receive() external payable {}

    function verifyWinner(uint256 _poolId) external view returns (address) {
        Pool storage pool = pools[_poolId];
        require(pool.winner != address(0), "Winner not selected");

        
        uint256 randomSeed = uint256(
            keccak256(
                abi.encodePacked(
                    pool.creationHash,
                    pool.participants.length,
                    pool.totalCollected
                )
            )
        );

        
        address[] memory allEntries = new address[](
            pool.totalCollected / pool.entryPrice
        );
        uint256 index = 0;

        for (uint256 i = 0; i < pool.participants.length; i++) {
            address participant = pool.participants[i];
            uint256 betCount = pool.betsByParticipant[participant];

            for (uint256 j = 0; j < betCount; j++) {
                allEntries[index] = participant;
                index++;
            }
        }

        
        uint256 randomIndex = randomSeed % allEntries.length;
        address expectedWinner = allEntries[randomIndex];

        require(expectedWinner == pool.winner, "Winner does not match");
        return expectedWinner;
    }
}

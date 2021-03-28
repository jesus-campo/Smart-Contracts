// SPDX-License-Identifier: UNLICENSED
// DELTA-BUG-BOUNTY
import "../libs/SafeMath.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import '@uniswap/v2-core/contracts/interfaces/IUniswapV2Pair.sol';
import "hardhat/console.sol";
import "../../interfaces/IDELTA_TOKEN.sol";
import "../../interfaces/IDEEP_FARMING_VAULT.sol";


interface ICORE_VAULT {
    function addPendingRewards(uint256) external;
}

contract DELTA_Distributor {
    using SafeMath for uint256;

    // defacto burn address, this one isnt used commonly so its easy to see burned amounts on just etherscan
    address constant internal DEAD_BEEF = 0xDeaDbeefdEAdbeefdEadbEEFdeadbeEFdEaDbeeF;
    address constant public WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    address constant public CORE = 0x62359Ed7505Efc61FF1D56fEF82158CcaffA23D7;
    address constant public CORE_WETH_PAIR = 0x32Ce7e48debdccbFE0CD037Cc89526E4382cb81b;
    address public DELTA_MULTISIG = 0xB2d834dd31816993EF53507Eb1325430e67beefa;
    address constant public CORE_VAULT = 0xC5cacb708425961594B63eC171f4df27a9c0d8c9;

    IDELTA_TOKEN immutable public DELTA_TOKEN;
    address public deepFarmingVault;

    // We sell 20% and distribute it thus
    uint256 constant public PERCENT_SOLD = 20;
    uint256 constant public PERCENT_OF_SOLD_DEV = 50;
    uint256 constant public PERCENT_OF_SOLD_CORE_BUY = 25;
    uint256 constant public PERCENT_OF_SOLD_DELTA_WETH_DEEP_FARMING_VAULT = 25;
    
    uint256 constant public PERCENT_BURNED = 16;
    uint256 constant public PERCENT_DEV_FUND= 8;
    uint256 constant public PERCENT_DEEP_FARMING_VAULT = 56;

    address immutable public DELTA_WETH_PAIR_UNISWAP;
    uint256 private pendingSellAmount;
    mapping(address => uint256) public pendingCredits;

    mapping(address => bool) public isApprovedLiquidator;


    receive() external payable {
        revert("ETH not allowed");
    }

    /// @notice a function that distributes pending to all the vaults etdc
    // This is able to be called by anyone.
    // And is simply just here to save gas on the distribution math
    function distribute() public {
        uint256 amountDeltaNow = DELTA_TOKEN.balanceOf(address(this));
        uint256 amountNew = amountDeltaNow.sub(pendingSellAmount);
        console.log("Distributor:: amountDeltaNow: ", amountDeltaNow);
        console.log("Distributor:: pendingSellAmount: ", pendingSellAmount);
        console.log("Distributor:: amountNew: ", amountNew);
        require(amountNew > 100, "Not enough to distribute");

        // We move the percent burned to deed beef adrresss ( the user pending credit is already here ready to be claimed)
        DELTA_TOKEN.transfer(DEAD_BEEF, amountNew.mul(PERCENT_BURNED).div(100));
        console.log("Distributor:: Burning tokens: ", amountNew.div(1e18));

        // We move the funds to dev fund
        address deltaMultisig = DELTA_TOKEN.governance();
        uint256 amountMultiSigbefore = DELTA_TOKEN.balanceOf(deltaMultisig);
        DELTA_TOKEN.transfer(deltaMultisig, amountNew.mul(PERCENT_DEV_FUND).div(100));
        uint256 amountMultiSigAfter = DELTA_TOKEN.balanceOf(deltaMultisig);
        require(amountMultiSigAfter == amountMultiSigbefore.add(amountNew.mul(PERCENT_DEV_FUND).div(100)), "Multisig Not whitelisted");

        
        address dfv = deepFarmingVault;
        // We send to the vault and credit it
        // /note includes a full seder check in case its misconfigured
        // this is not a gas cost maximising function
        uint256 amountVaultBefore = DELTA_TOKEN.balanceOf(dfv);
        IDEEP_FARMING_VAULT(dfv).addNewRewards(amountNew.mul(PERCENT_DEEP_FARMING_VAULT).div(100), 0);
        uint256 amountVaultAfter = DELTA_TOKEN.balanceOf(dfv);
        require(amountVaultAfter == amountVaultBefore.add(amountNew.mul(PERCENT_DEEP_FARMING_VAULT).div(100)), "Vault Not whitelisted");
        

        // Reserve is how much we can sell thats remaining 20%
        pendingSellAmount = DELTA_TOKEN.balanceOf(address(this));
    }

    function deltaGovernance() public view returns (address) {
        return DELTA_TOKEN.governance();
    }
    function onlyMultisig() private view {
        require(msg.sender == deltaGovernance(), "!governance");
    }

    function setDeepFarmingVault(address _deepFarmingVault) public {
        onlyMultisig();
        deepFarmingVault = _deepFarmingVault;
        // set infinite approvals
        DELTA_TOKEN.approve(deepFarmingVault, uint(-1));
        IERC20(WETH).approve(deepFarmingVault, uint(-1));
    }

    constructor (address _deltaToken) public {
        DELTA_TOKEN = IDELTA_TOKEN(_deltaToken);
    
        // we check for a correct config
        require(PERCENT_SOLD + PERCENT_BURNED + PERCENT_DEV_FUND + PERCENT_DEEP_FARMING_VAULT == 100, "Amounts not proper");
        require(PERCENT_OF_SOLD_DEV + PERCENT_OF_SOLD_CORE_BUY + PERCENT_OF_SOLD_DELTA_WETH_DEEP_FARMING_VAULT == 100 , "Amount of weth split not proper");

        // calculate pair
        DELTA_WETH_PAIR_UNISWAP = address(uint(keccak256(abi.encodePacked(
                hex'ff',
                0x5C69bEe701ef814a2B6a3EDD4B1652CB9cc5aA6f, // Mainned uniswap factory
                keccak256(abi.encodePacked(_deltaToken, WETH)),
                hex'96e8ac4277198ff8b6f785478aa9a39f403cb768dd02cbee326c3e7da348845f' // init code hash
        ))));

    }   



    function getWETHForDeltaAndDistribute(uint256 amountToSellFullUnits, uint256 amountWETHOutFullUnits, uint256 minAmountCOREUnitsPer1WETH) public {
        require(isApprovedLiquidator[msg.sender] == true, "!approved liquidator");
        distribute(); // we call distribute to get rid of all coins that are not supposed to be sold
        // We swap and make sure we can get enough out
        // require(address(this) < wethAddress, "Invalid Token Address"); in DELTA token constructor
        IUniswapV2Pair pairDELTA = IUniswapV2Pair(DELTA_WETH_PAIR_UNISWAP);
        (uint256 reservesDELTA, uint256 reservesWETHinDELTA, ) = pairDELTA.getReserves();
        uint256 deltaUnitsToSell = amountToSellFullUnits * 1 ether;
        uint256 amountETHOut = getAmountOut(deltaUnitsToSell, reservesDELTA, reservesWETHinDELTA);
        // Check that we got enough 

        console.log('amountETHOut', amountETHOut, 'amountWETHOutFullUnits', amountWETHOutFullUnits);
        require(amountETHOut >= amountWETHOutFullUnits * 1 ether, "Did not get enough ETH to cover min");
        require(deltaUnitsToSell <= DELTA_TOKEN.balanceOf(address(this)), "Amount is greater than reserves");

        // We swap for eth
        DELTA_TOKEN.transfer(DELTA_WETH_PAIR_UNISWAP, deltaUnitsToSell);
        pairDELTA.swap(0, amountETHOut, address(this), "");
        address dfv = deepFarmingVault;

        // We transfer the splits of WETH
        IERC20 weth = IERC20(WETH);
        weth.transfer(DELTA_MULTISIG, amountETHOut.div(2));
        IDEEP_FARMING_VAULT(dfv).addNewRewards(0, amountETHOut.div(4));
        /// Transfer here doesnt matter cause its taken from reserves and this does nto update
        weth.transfer(CORE_WETH_PAIR, amountETHOut.div(4));
        // We swap WETH for CORE and send it to the vault and update the pending inside the vault
        IUniswapV2Pair pairCORE = IUniswapV2Pair(CORE_WETH_PAIR);

        (uint256 reservesCORE, uint256 reservesWETHCORE, ) = pairCORE.getReserves();
         // function getAmountOut(uint256 amountIn, uint256 reserveIn, uint256 reserveOut) internal  pure returns (uint256 amountOut) {

        uint256 coreOut = getAmountOut(amountETHOut.div(4), reservesWETHCORE, reservesCORE);
        uint256 coreOut1WETH = getAmountOut(1 ether, reservesWETHCORE, reservesCORE);

        require(coreOut1WETH >= minAmountCOREUnitsPer1WETH, "Did not get enough CORE check amountCOREUnitsBoughtFor1WETH() fn");
        pairCORE.swap(coreOut, 0, CORE_VAULT, "");
        // uint passed is deprecated
        ICORE_VAULT(CORE_VAULT).addPendingRewards(0);

        pendingSellAmount = DELTA_TOKEN.balanceOf(address(this)); // we adjust the reserves
    }   

    function editApprovedLiquidator(address liquidator, bool isLiquidator) public {
        require(msg.sender == DELTA_MULTISIG, "!multisig");
        isApprovedLiquidator[liquidator] = isLiquidator;
    }
    
    address public pendingOwner;

    /// @dev note this can overwrite pending owner on purpose or it would be nonsense to even have pending owner
    function changePendingOwner(address newOwner) public {
        require(newOwner != address(0), "Can't be address 0");
        require(msg.sender == DELTA_MULTISIG, "Only multisig can change multisig");
        pendingOwner = newOwner;
    }

    function acceptOwnership() public {
        require(msg.sender == pendingOwner, "!pending owner");
        require(pendingOwner != address(0));
        DELTA_MULTISIG = pendingOwner;
        pendingOwner = address(0);
    }

    function amountCOREUnitsBoughtFor1WETH() public view returns(uint256) {
        IUniswapV2Pair pair = IUniswapV2Pair(CORE_WETH_PAIR);
        // CORE is token0
        (uint256 reservesCORE, uint256 reservesWETH, ) = pair.getReserves();
        return getAmountOut(1 ether, reservesWETH, reservesCORE);
    }


    function getAmountOut(uint256 amountIn, uint256 reserveIn, uint256 reserveOut) internal  pure returns (uint256 amountOut) {
        require(amountIn > 0, 'UniswapV2Library: INSUFFICIENT_INPUT_AMOUNT');
        require(reserveIn > 0 && reserveOut > 0, 'UniswapV2Library: INSUFFICIENT_LIQUIDITY');
        uint amountInWithFee = amountIn.mul(997);
        uint numerator = amountInWithFee.mul(reserveOut);
        uint denominator = reserveIn.mul(1000).add(amountInWithFee);
        amountOut = numerator / denominator;
    }

    function rescueTokens(address token) public {
        require(msg.sender == DELTA_MULTISIG, "!Multigig");
        IERC20(token).transfer(msg.sender,IERC20(token).balanceOf(address(this)));
    }


    // Allows users to claim free credit
    function claimCredit() public {
        uint256 pending = pendingCredits[msg.sender];
        require(pending > 0, "Nothing to claim");
        pendingCredits[msg.sender] = 0;
        IDEEP_FARMING_VAULT(deepFarmingVault).addPermanentCredits(msg.sender, pending);
    }

    /// Credits user for burning tokens
    // Can only be called by the delta token
    // Note this is a inherently trusted function that does not do balance checks.
    function creditUser(address user, uint256 amount) public {
        require(msg.sender == address(DELTA_TOKEN), "KNOCK KNOCK");
        pendingCredits[user] = pendingCredits[user].add(amount.mul(PERCENT_BURNED).div(100)); //  we add the burned amount to perma credit
    }


    function addDevested(address user, uint256 amount) public {
        require(DELTA_TOKEN.transferFrom(msg.sender,address(this), amount),"Did not transfer enough");
        pendingCredits[user] = pendingCredits[user].add(amount.mul(PERCENT_BURNED).div(100)); //  we add the burned amount to perma credit
    }




}
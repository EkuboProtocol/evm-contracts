import {BaseOrdersTest} from "./Orders.t.sol";
import {RevenueBuybacks, IOrders} from "../src/RevenueBuybacks.sol";

contract RevenueBuybacksTest is BaseOrdersTest {
    RevenueBuybacks rb;

    function setUp() public override {
        BaseOrdersTest.setUp();
        rb = new RevenueBuybacks(IOrders(address(orders)));
    }

    function test_mint_on_create() public {
        assertEq(orders.ownerOf(rb.nftId()), address(rb));
    }
}

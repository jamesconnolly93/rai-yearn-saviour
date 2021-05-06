### Link to Strategy Repository
The Yearn Strategy and integration tests can be found [here](https://github.com/jamesconnolly93/rai-x-yearn-strategy)

### Description of Strategy
This strategy has been designed using one of the highest TVL strategies from Yearn Finance: [Generic-Lender](https://github.com/Grandthrax/yearnV2-generic-lender-strat). This strategy uses a lender-agnostic approach to optimize the routing of new deposits withdraws across an arbitrary number of lending platforms according to best-APY. This is done by using "plug-in" contracts which map the various platform APIs back to the common Generic Lender strategy API (shown in the diagram below). Although RAI only exists on limited lending platforms today, there are pre-written plugins that exist for the following lending platforms that can be leveraged immediately if RAI were to be added:
- Compound
- Aave
- Fuse 
- Alpha Homora
- Cream
- DyDx

This codebase has been both reviewed and formally audited, and is utilized on just about every production v2 vault that Yearn has.

![](https://i.imgur.com/P0qyI8e.png)

#### Generic Lender Overview and Key Advantages
The Generic Lender strategy contract is designed to allow a vault to lend funds to multiple lending platforms and autobalances in order to achieve the best APY. This strategy offers a highly omptimized, gas efficient methodology for allowing RAI holders to maximize the yield on their assets over time.

Whenever the `harvest` function is called (e.g. once daily), depending on the conditions of the vault, funds may be added to the strategy or removed from the strategy. In both cases, the Generic Lender optimizes which lenders to remove or add funds to. It does this by cycling through the available lenders and rebalance by:
1. Identifying the lowest yielding platform and determining the amount that should be withdrawn from that platform
2. Identifying the highest yielding platform and determining the amount that should be deposited into it

Importantly, the expected yield on the platform that is being deposited is calculated _post-deposit_ ensuring that if large deposits are being made, the strategy is properly accounting for any downward pressure on yields that this could create.

If ever necessary, a function is made available to authorized users to define a custom allocation across available lenders, effectively overriding the strategy's default behavior.

Similar to how we optimize allocation of inbound funds, there are efficiencies realized on outbound funds. Whenever a user calls `withdraw`, the strategy will similarly cycle through the various platforms and identify the lowest yielding one and selectively withdraw funds from that one. If not enough funds are available from the lowest yielding platform to fulfill the withdrawal, the process repeats.

The net effect of these features is that every time funds are deposited, they are allocated to the highest yielding option, and when funds are withdrawn they are withdrawn from the lowest yielding option. This results in the overall vault APY increasing each time a user withdraws from the vault.

One additional feature of this strategy is that it  implements `tend` function that identifies whether the yield gains of rebalancing outweight gas costs. There is also a `tendTrigger` function which automates this decision and signals to keepers when it makes sense to call `tend`.

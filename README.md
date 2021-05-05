### Description of Strategy
This strategy has been designed using the generic lender contract found here: https://github.com/Grandthrax/yearnV2-generic-lender-strat. This approach allows this strategy to be implemented largely using code that has already been audited by the Yearn team and also offers a number of features optimised for this use case.

![](https://i.imgur.com/P0qyI8e.png)

#### Generic Lender Overview and Key Advantages
The generic lender strategy contract is designed to allow a vault to lend funds to multiple lending platforms and autobalances in order to achieve the best APY. This strategy offers a highly omptimized, gas efficient methodology for allowing RAI holders to maximize the yield on their assets over time.

Whenever the `harvest` function is called (approximately once daily), depending on the conditions of the vault, funds may be added to the strategy or removed from the strategy. In both cases, the generic lender optimizes which lenders to remove or add funds to. It does this by cycling through the available lending platforms and rebalance by:
1. Identifying the lowest yielding platform and determining the amount that should be withdrawn from that platform
2. Identifying the highest yielding platform and determining the amount that should be deposited into it

Importantly, the expected yield on the platform that is being deposited is calculated _post-deposit_ ensuring that if large deposits are being made, the strategy is properly accounting for any downward pressure on yields that this could create.

Whenever a user calls a `withdraw`, the strategy will similarly cycle through the various platforms and identify the lowest yielding one and selectively withdraw funds from that one. If not enough funds are available from the lowest yielding platform to fulfill the withdrawal, the process repeats.

The net effect of these features is that every time funds are deposited, they are allocated to the highest yielding option, and when funds are withdrawn they are withdrawn from the lowest yielding option. This results in the overall vault APY increasing each time a user withdraws from the vault.

One additional feature of this strategy is that it  implements `tend` function that identifies whether the yield gains of rebalancing outweight gas costs. There is also a `tendTrigger` function which automates this decision and signals to keepers when it makes sense to call `tend`.



#### Platform-Specific Plugins
The plugin contracts allow our Generic Lender to inferface with lending platforms. For the purposes of this submission, plugins for Cream and Fuse have been implemented. A major benefit of the approach taken is that adding new lending platforms such as Aave or Compound can be easily achieved, plugins can be updated as needed and also removed if they are no longer desired.

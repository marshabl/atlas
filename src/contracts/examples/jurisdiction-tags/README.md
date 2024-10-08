Jurisdiction Dapp Using Atlas
In this [post](https://a16zcrypto.com/posts/article/application-tokens-economic-model-cash-flows/), authors suggest that protocols need ways to abide by jurisdictional regulations by leveraging frontends to implement the necessary logic to legally capture protocol fees. The authors outline fee traceability as the key ingredient to make this possible. With Atlas, this becomes easily achievable for any Dapp. 

In my example, I use Uniswap V2 router to showcase how we can “tag” users and pools as jurisdictionally compliant in order to allow users to collect fees from a uniswap router that satisfy whatever laws are required by that jurisdiction. Imagine that the US government implements a legal framework for defi. This framework effectively stipulates that US users can only use frontends that have satisfactorily registered and comply with the legal framework. Once the frontend gets the “off-chain” green light to operate a uniswap frontend, they need to ensure two things:
1. US users pass whatever KYC and then they are “tagged” onchain allowing them to use the frontend.
2. Only approved Token pools can be launched on the frontend

This means that anyone interacting with this uniswap router, whether they are swapping or providing liquidity on a token pool, is only interacting with approved pools and users. In order to achieve this, we introduce a new ERC for “tagging”. This ERC allows any user (in this case Dapp users of the Atlas protocol) to create a new tag contract (like creating a ERC20 token contract). The DappControl contract inherits from the Tag ERC contract giving the Dapp the power to tag any address. In other words, the DappControl can initialize a US Jurisdiction Tag contract that allows it to tag users or pools as approved for this jurisdiction. Now the sequence of events for the Dapp becomes straightforward:
1. Imagine the Dapp goes through some process to register and comply with USG defi framework giving it the green light to build a DappControl with the US Jurisdiction Tag contract 
2. Launch the DC onchain
3. Every user must KYC and accept the terms of service on the frontend. Then when they create an account, an ExecutionEnvironment contract will be created for them and that contract will be tagged by the DC as a compliant user and allowed to interact with the Dapp
4. Whenever someone wants to launch a new pool, the user would have to be tagged and the new pool will also be tagged after it’s been created (ie. createPair). 
5. Now if a user wants to addLiquidity to the pool, they would have to be tagged.
6. Any user that wants to swap on that pool would have to be tagged
7. Therefore all fees generated by that pool would necessarily be tagged and compliant with the jurisdiction

You now have a fully compliant and silo’d uniswap V2 router and factory where all fees are tagged and traceable. You can then imagine how this would be applicable for any Dapp (Curve, Aave, Compound, etc). Atlas + the Tag ERC make it very easy to create traceable fees to abide by jurisdictional requirements.

Notes:
1. I tag the ExecutionEnvironment after it has been created, but it might make more sense to tag it directly in the EE constructor
2. I assume the protocol fee split in the Uniswap fork is turned off, but you could imagine turning it on. Then, you could mirror the suggestions from the article. There could be a different governance token for the jurisdiction and you can stake that governance token in order to collect fees from the protocol fee split
3. While the Tag ERC is very useful for this specific example, it is very generalizable and could be paired with Atlas in many ways:
    1. You could tag users after they complete certain actions or milestones which lead to different incentives within the Dapp
    2. You could tag solvers as good or bad actors which could have multipliers or prioritization on their bids
4. I had to [update this line](https://github.com/marshabl/atlas/blob/main/src/contracts/atlas/GasAccounting.sol#L420) in GasAccounting.sol to make my tests work without solvers
5. You could probably add some interesting solver features on top of the createPair userOps. This is the classic use case for telegram bots. They snipe createPair and make a private bundle, but this could be done via Atlas.

Relevant Files:
- [Jurisdiction Tags Example](https://github.com/marshabl/atlas/tree/main/src/contracts/examples/jurisdiction-tags)
- [V2JurisdictionDAppControl Test](https://github.com/marshabl/atlas/blob/main/test/V2JurisdictionDAppControl.t.sol)
- [V2FactoryJurisdictionDAppControl Test](https://github.com/marshabl/atlas/blob/main/test/V2FactoryJurisdictionDAppControl.t.sol)

Usage
- You can run the two tests with:
    * forge test --match-path test/V2JurisdictionDAppControl.t.sol -vv
    * forge test --match-path test/V2FactoryJurisdictionDAppControl.t.sol -vv
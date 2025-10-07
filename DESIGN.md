# DESIGN

Gm, this is a document explaining specific design decisions and compromises. 
Here is a stream of thought on the design & implementation decisions as I started out.

## Flow

- We need a relayer from chainA to chainB. 
Let's build it all locally with a bash script and startup 2 anvil nodes with different chainIDs. No forks needed here, and we can use the default addresses.

- What problems have I had with relayers before that can be adressed here?
With certain relayers, when messages failed to be transmitted, I had to contact the team to ask them about the error log. This is not very user friendly, let's fail onchain if we can & and report back to the origin chain, so the user can simply check, without switching, if the tx has been transmitted successfully. 

- What should the basic architecture be?
Foundry repo + ts relayer repo that can be dockerized, for easy startup and convenient. Relayer would also possibly need an exposed health and status metrics.

- How should we handle failures?
We should fail on chain whenever possible, and have a resistant ts relayer that could easily restart (without docker, always on) with a built in retry mechanism.
Also let's support PARTIALLY_DELIVERED blocks.

Note: the .env have been shown, there is no need to hide it, as we use the default addresses.

## Shortcomings

The typescript side has not been tested extensively, there is also no test-suite. it works for the demo.
The contracts are good but have been designed quickly and there may be a better way to solve this.
For example we would need way to retry PARTIALLY_DELIVERED blocks, resubmit the failed messages with a new id and allow the relayer to safely retransmit messages without changing core functionality.

The Makefile has been written fast and could be updated and be smoother. Sometimes processes end with error 2 but they are succesful. 


## With More Time

The Makefile and user scripts definitely need to be updated (for portability) and easier access and the relayer needs more tests. Some values have been hardcoded for faster iteration but it's less portable. Also the previously mentioned function to resubmit partially delivered blocks would be helpful. 	


## AI Coding

Yes, for fast prototyping, and writing documentation and docs & the readme.md drafts.

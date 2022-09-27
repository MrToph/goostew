# GooStew - Technical paper

## Goo Production Mechanism

First, we state definitions from the [official Goo Paper](https://www.paradigm.xyz/2022/09/goo) followed by some insights:

1. goo balance $g(t, m, \textrm{goo}) = 0.25 t^2 m + t \sqrt{m \cdot \textrm{goo}} + \textrm{goo}$
1. instantaneous goo production: $g'(m, \textrm{goo} = g(t)) = \sqrt{m \cdot \textrm{goo}}$
1. goo production $\Delta g(t, m, \textrm{goo}) = g(t, m, \textrm{goo}) 1. \textrm{goo} = t^2 m + t \sqrt{m \cdot \textrm{goo}}$
1. goo auto-compounds: $g(t_0 + t_1, m, \textrm{goo}) = g(t_1, m, g(t_0, m, \textrm{goo}))$
1. optimally distributed goo among several gobblers is equal to the total goo distributed to a single gobbler with the sum of their multiples: $g(t, M, \textrm{GOO}) = \sum_i g(t, m_i, \frac{m_i}{M} * \textrm{GOO})$ with $M = \sum_i m_i$, $\textrm{GOO} = \sum_i \textrm{goo}_i$

## GooStew

Users can deposit an arbitrary amount (including 0) of gobblers and/or goo. As the `ArtGobblers` contract already balances goo optimally _for individual users_ and because of equation (5) we can model a multi-gobbler deposit by a user as a single-gobbler deposit $(m_i, \textrm{goo}_i)$ with totalled emission multiple $m_i$.

> **Note**
> Equation (5) is also the reason why the GooStew protocol leads to better goo production. In practice, the gobbler & goo pots of different users don't distribute the total goo optimally: $g(t, M, \textrm{GOO}) \geq \sum_i g(t, m_i, \textrm{goo}_i)$.

When gobblers are deposited, the protocol mints an NFT to the user which identifies the IDs of the gobblers.
When depositing goo, the protocol mints _goo share tokens_ at a _goo share price_ of $\frac{\textrm{totalGoo}}{\textrm{sharesTotalSupply}}$. The shares can be redeemed for a fair proportion of the underlying `totalGoo` at any time. The NFT can be redeemed for its gobblers and a fair share $(m_i / M)$ of gobbler-assigned inflation.

Whenever a `deposit` or `redeem` happens, we first claim the new goo inflation $\Delta g(\textrm{timeElapsed}, M, \textrm{totalGoo})$ and distribute it into two buckets:

- the goo amount $r_\textrm{gobbler}$ goes to all gobbler depositors
- the goo amount $r_\textrm{goo} = \Delta g(\textrm{timeElapsed}, M, \textrm{totalGoo}) - r_\textrm{gobbler}$ goes to all goo shares holders

For the protocol to be fair to gobbler depositors with regards to the compounding nature of an update step, the goo amount $r_\textrm{gobbler}$ is issued as an _equivalent amount of goo shares_ to the gobblers instead.
Then `totalGoo` is increased by the new goo inflation $r_\textrm{gobbler} + r_\textrm{goo}$ and added back into `ArtGobblers` to produce more goo.

Choosing correct $(r_\textrm{gobbler}, r_\textrm{goo})$ is essential to ensure the protocol is a **no-loss protocol**. We measure the contribution of all gobblers as $r_\textrm{gobbler} = 0.25 t^2 M +  0.5 t \sqrt{M \cdot \textrm{totalGoo}}$. [^1]
This has been fuzz-tested in [`testNoLoss`](./test/GooStew.t.sol) to satisfy the _no-loss property_.

## Implementation

The inflation is received as _goo amounts_ but it needs to be distributed to two different non-comparable elements, **goo and gobblers**. Efficiently computing the inflation distribution in the smart contract is done by:

- inflation for goo depositors: issuing shares tokens on goo deposits which are a proportional claim on the total goo amount. The goo inflation $r_\textrm{goo}$ can directly be attributed to the total goo amount.
- inflation for gobbler depositors: The gobbler goo inflation $r_\textrm{gobbler}$ is issued as goo shares (at the new price after attributing $r_\textrm{goo}$ to the shares holders) and we use a `MasterChef`-style reward index (`_gobblerSharesPerMultipleIndex`) for each staking NFT to keep track of how many shares the NFT can be redeemed for. This way we only need to "mint" the total shares amount on each update but can postpone minting each individual depositor's shares until redemption.

The full implementation is available as [GooStew.sol](./src/GooStew.sol).

## Further research

1. To incentivize developers building this and other projects in the ArtGobblers ecosystem, the protocol could take a performance fee on the additional goo production. However, we can't efficiently compute the **additional** goo production in the smart contract: $g(t, M, \textrm{GOO}) - \sum_i g(t, m_i, \textrm{goo}_i)$ as $g(t, m_i, \textrm{goo}_i)$ changes non-linearly for each user on each update.

[^1]: The gobblers contribute the $M$ in $\Delta g(t, M, \textrm{GOO})$, therefore $t^2M$ is fully attributed to the gobblers. For the mixed term $t\sqrt{M\cdot \textrm{GOO}}$, just taking half of it works for some reason.

# Appendix

### No-loss property

We want to show that for a user depositing $(m, g)$ and redeeming after some time $t$, their goo balance is at least as large as their goo balance would be without using the protocol.
LHS is what they get after redeeming. RHS is what they would have received on their own.


$$
\begin{align*}
\frac{m}{M}   r_\textrm{gobbler} + \frac{g}{G}   (r_\textrm{goo} + G) &\geq 0.25 m t^2 + t \sqrt{m g} + g \\
\frac{m}{M}   (0.25 M t^2 + 0.5 t \sqrt{M G}) + \frac{g}{G}   (0.5 t \sqrt{M G} + G) &\geq 0.25 m t^2 + t \sqrt{m g} + g \\
\frac{m}{M}   (0.25 M t^2 + 0.5 t \sqrt{M G}) + \frac{g}{G}   0.5 t \sqrt{M G} &\geq 0.25 m t^2 + t \sqrt{m g} \\
\frac{m}{M} 0.5 t \sqrt{M G} + \frac{g}{G}   0.5 t \sqrt{M G} &\geq t \sqrt{m g} \\
\frac{(\frac{m}{M} + \frac{g}{G})}{2} \sqrt{M G} &\geq \sqrt{m g}
\end{align*}
$$

This is [true](https://www.wolframalpha.com/input?i=solve+%28m%2FM+%2B+g%2FG%29%2F2+*+sqrt%28M*G%29+%3E%3D+sqrt%28m*g%29%2C+m%3E%3D0%2Cg%3E%3D0%2CM%3E%3Dm%2CG%3E%3Dg%2C+t+%3E+0).

<!-- (m/M) _ r\_\textrm{gobbler} + (g/G) _ (r\_\textrm{goo} + G) >= 0.25*m*t^2 + t*sqrt(m*g) + g
(m/M) * (0.25*M*t^2 + 0.5*t*sqrt(M*G)) + (g/G) * (0.5*t*sqrt(M*G) + G) >= 0.25*m*t^2 + t*sqrt(m*g) + g
(m/M) * (0.25*M*t^2 + 0.5*t*sqrt(M*G)) + (g/G) * 0.5*t*sqrt(M*G) >= 0.25*m*t^2 + t*sqrt(m*g)
(m/M) * (0.5*t*sqrt(M*G)) + (g/G) * 0.5*t*sqrt(M*G) >= t*sqrt(m*g)
(m/M + g/G) * 0.5*t*sqrt(M*G) >= t*sqrt(m*g)
(m/M + g/G)/2 * sqrt(M*G) >= sqrt(m*g) -->

This shows that it's a no-loss for a _single_ update step but as $r_\textrm{gobbler}$ is reinvested _for gobblers_ as goo (by issuance of goo shares) and by the compounding property of $g$, this extends to multiple update/compounding steps.

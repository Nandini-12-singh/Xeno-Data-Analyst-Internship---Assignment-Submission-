# Comm-Log Reconciliation

Merchant 501, October 2026. Finance's reported `target_base` is 22 — this is how I arrived at that number.

I started with the simplest query I could think of and worked forward from there, checking against 22 after every change, instead of starting from the rules and writing one clean query top-down.

## Reconciliation Bridge

| Step | Description | Result | Reason |
|------|------|------|--------|
| 0 | Naive count — `SELECT COUNT(*) FROM communication_log;` | 30 | Starting point: count of all send rows for merchant 501, October 2026, Diwali campaigns |
| 1 | Excluded campaign 9004 | 26 | `creation_status = 'approval_awaiting'` — this campaign's sends already exist in `communication_log`, but the approval workflow hadn't cleared yet, so it shouldn't count toward reported sends |
| 2 | Collapsed retry chain 9001 → 9002 → 9003 to distinct customers | 10 | These three campaigns represent retries of the same underlying communication (`parent_id` chains back to 9001). A customer retried multiple times within this chain should be counted once, not once per attempt |
| 3 | Collapsed retry chain 9201 → 9202 to distinct customers | 5 | Same logic as above — 9202 is a retry of 9201 |
| 4 | Kept campaign 9101 rows as-is | 7 | 9101 has no parent and no retries pointing at it, so it's a standalone communication. Every send under it is a separate event, even when the same customer (C20) appears twice |
| **Final** | 10 + 5 + 7 | **22** | Matches Finance's reported `target_base` |

I got to 26 pretty quickly since campaign 9004 stood out on its own — its `creation_status` was different from every other row, and honestly its name gave it away too ("Retry C (pending)"). The retry chains took a bit longer to notice since I had to actually look at `parent_id` instead of just eyeballing the campaign names, and 9101 was the last piece — I almost collapsed it the same way as the other two chains before realizing it isn't a chain at all, nothing points to it and it points to nothing.

## SQL Query

See `query.sql` for two versions, both returning 22:

1. **Direct query** — built from the specific campaign IDs I identified during the investigation (9001–9003, 9201–9202, 9101). This is basically the query that matches the bridge above step-by-step.
2. **Generalized query** — uses a recursive CTE to identify retry chains automatically via `parent_id`, excludes campaigns still in `approval_awaiting`, then counts distinct customers within each retry chain and raw row counts for standalone campaigns. I wrote this version because the first one felt like it was cheating a bit — I already knew where the campaign IDs were, so hardcoding them into the query doesn't really prove the logic is right, it just proves I can plug in numbers I already found manually. This version would still hold up even if the chain structure changed or new campaigns got added.

I also tested the generalized version against a few slightly modified copies of the data (marking a mid-chain campaign as pending, adding a duplicate standalone send, and reusing a customer ID across two different chains) just to make sure 22 wasn't a coincidence tied to this one file — all three came back with the numbers I expected, which gave me some confidence the logic actually generalizes and isn't just fit to this dataset.

## What Surprised Me

Campaign 9004 already had send rows in `communication_log` even though its `creation_status` was still `approval_awaiting` — the send pipeline had run ahead of the approval workflow, which wasn't something I expected going in. I'd have assumed sends physically can't go out before a campaign is approved, but apparently that's not how the system works.

I also noticed a single customer (C20) appeared twice against the standalone campaign (9101), on two different dates. At first glance this looked exactly like the retry pattern I'd just handled for the other campaigns, so my first instinct was to collapse it too. But since 9101 has no `parent_id` and nothing points back at it, both sends count as separate events rather than being collapsed — which turned out to be the one adjustment that actually pushed the number up instead of down.

# Comm-Log Reconciliation

Merchant 501, October 2026. Finance's reported `target_base` is 22 — this is how I got there.

I started with the simplest query I could think of and worked forward from there, checking against 22 after every change I made, instead of starting from the rules and writing one clean query top-down. The bridge below is basically the order I actually figured things out in.

## Reconciliation Bridge

| Step | Description | Result | Reason |
|:----:|---|:----:|---|
| 0 | Naive count — `COUNT(*)` on `communication_log` | 30 | Baseline: every send row for merchant 501, Oct 2026 |
| 1 | Excluded campaign 9004 | 26 | `creation_status = 'approval_awaiting'` — sends exist, but approval never cleared, so it doesn't count   yet |
| 2 | Collapsed chain 9001 → 9002 → 9003 to distinct customers | 10 | Same underlying message, retried twice — a customer retried within a chain counts once, not per attempt |
| 3 | Collapsed chain 9201 → 9202 to distinct customers | 5 | Same logic — 9202 is a retry of 9201 |
| 4 | Kept campaign 9101 rows as-is | 7 | No parent, no retries pointing at it — standalone. Every send is its own event, even when C20 repeats |
| Final | 10 + 5 + 7 | 22 | Matches Finance's reported `target_base` |

### Going through it step by step

**Step 0.** First thing I did was just run `SELECT COUNT(*) FROM communication_log` to see what the "obvious" answer looks like. Got 30 — nowhere near 22, so I knew there was some actual structure I was missing, not just a small filter I'd forgotten.

**Step 1.** Looking at the `campaign` table directly, one row stood out immediately — campaign 9004. Its name literally has "(pending)" in it, and its `creation_status` (`approval_awaiting`) didn't match any other row (everything else says `approved`). I checked the data dictionary and it confirmed: a campaign still awaiting approval doesn't count toward reported sends, even though its sends had already gone out and were delivered. Excluding it brought me from 30 to 26. Honestly this was the part that surprised me most — I'd have assumed sends physically can't happen before a campaign is approved, but apparently the send pipeline doesn't wait for that.

**Step 2.** Still not at 22, so I looked at `parent_id` more carefully. Turns out 9002's parent is 9001, and 9003's parent is 9002 — so these aren't three separate campaigns, they're the same message being retried because it kept failing. Customer C2 failed in 9001, got retried in 9002, and it worked. Customer C3 took three tries (9001 → 9002 → 9003) before it landed. Counting distinct customers instead of raw rows for this chain gives 10, not 13 — the retries don't add new people, they're just extra attempts at reaching the same person.

**Step 3.** Same pattern with 9201 → 9202 — customer D1 failed once and got retried, everyone else went through on the first try. Distinct customers here: 5.

**Step 4.** I was at 15 (10 + 5) and needed 7 more to hit 22. That's when I went back to campaign 9101 and checked its `parent_id` — null. Then I checked whether anything else points to 9101 as a parent — nothing does. So it isn't part of a chain at all. Customer C20 was sent to twice under this campaign (two different dates, both delivered), but that's not a retry — nobody failed and got resent, it's just two independent sends that happened to land on the same person. If I collapsed this the same way I did for the other two chains, I'd get 6, not 7, and the total would be 21, not 22. Leaving it as a raw row count was the one adjustment that pushed the number up instead of down.

**Final.** 10 + 5 + 7 = **22**, matching Finance's number.

The part that took me longest to actually get was realizing that "the same customer appears twice" means two completely different things depending on context — inside a retry chain it means "count once," inside a standalone campaign it means "count twice." Nothing in the row itself tells you which case you're in; you have to check the campaign's `parent_id` structure first.

## SQL Query

See `query.sql` for two versions, both returning 22:

1. **Direct query** — built from the specific campaign IDs I identified during the investigation (9001–9003, 9201–9202, 9101). This one basically mirrors the bridge above step by step.

2. **Generalized query** — uses a recursive CTE to identify retry chains automatically via `parent_id`, excludes campaigns still in `approval_awaiting`, then counts distinct customers within each retry chain and raw row counts for standalone campaigns. I wrote this version because the first one felt like it was cheating a bit — I already knew where the campaign IDs were by that point, so hardcoding them into a query doesn't really prove the logic is right, it just proves I can plug in numbers I already found manually. This version would still hold up even if the chain structure changed or new campaigns got added later.



### Making sure it wasn't a fluke

Getting 22 once doesn't prove much on its own — the query could just happen to work for this exact file. So I made a few copies of the database and tweaked them slightly, then ran the same query again unchanged, just to see if it still behaved logically:

- **Marked 9002 as `approval_awaiting`** — number stayed at 22. Made sense once I thought about it: C2 and C3 (9002's customers) were already counted through 9001 anyway, so removing 9002 doesn't lose anyone new.
- **Added a second send to C21** under the standalone campaign — number went to 23, which is what I'd expect since standalone sends don't collapse.
- **Renamed a customer in chain B to "C1"** (same ID already used in chain A), to check if the query would wrongly merge the two chains together — it didn't, stayed at 22, because the query groups by root campaign first before counting distinct customers, so IDs from different chains never mix.

All three came out exactly how the underlying rules predict, which gave me decent confidence this isn't just fit to one dataset.

## What Surprised Me

Campaign 9004 already had send rows in `communication_log`, fully delivered, even though its `creation_status` was still `approval_awaiting`. The send pipeline had run ahead of the approval workflow — not something I expected going in. I'd have assumed sends physically can't go out before a campaign clears approval, but apparently that's not how the system works.

I also noticed customer C20 appeared twice under the standalone campaign (9101), on two different dates. At first glance this looked exactly like the retry pattern I'd just handled for the other campaigns, so my first instinct was to collapse it the same way. But since 9101 has no `parent_id` and nothing points back at it, both sends genuinely count as separate events — this turned out to be the one adjustment in the whole exercise that pushed the number *up* instead of down.

Small thing, but campaign 9004's name literally had "(pending)" written into it — a reminder that sanity-checking the human-readable fields, not just status codes, can save time when something's off.

-- Version 1: uses the exact campaign IDs I found during investigation
SELECT
  (SELECT COUNT(DISTINCT customer_id) FROM communication_log WHERE communication_id IN (9001, 9002, 9003))
  +
  (SELECT COUNT(DISTINCT customer_id) FROM communication_log WHERE communication_id IN (9201, 9202))
  +
  (SELECT COUNT(*) FROM communication_log WHERE communication_id = 9101)
  AS target_base;


-- Version 2: generalized — derives chains from parent_id instead of hardcoding IDs
WITH RECURSIVE chain_root AS (
    -- a campaign with no parent is the root of its own chain
    SELECT id, id AS root_id
    FROM campaign
    WHERE parent_id IS NULL

    UNION ALL

    -- every other campaign inherits its parent's root
    SELECT c.id, cr.root_id
    FROM campaign c
    JOIN chain_root cr ON c.parent_id = cr.id
),
valid_campaigns AS (
    -- keep only campaigns that are actually approved and sent
    SELECT chain_root.id, chain_root.root_id
    FROM chain_root
    JOIN campaign ON campaign.id = chain_root.id
    WHERE campaign.creation_status != 'approval_awaiting'
      AND campaign.processing_status = 'processed'
),
is_chain AS (
    -- number of campaigns under each root, to tell chains from standalone
    SELECT root_id, COUNT(*) AS chain_size
    FROM valid_campaigns
    GROUP BY root_id
)
SELECT SUM(customer_count) AS target_base
FROM (
    SELECT
        vc.root_id,
        CASE
            WHEN ic.chain_size > 1 THEN COUNT(DISTINCT cl.customer_id)  -- part of a chain: collapse retries
            ELSE COUNT(*)                                                -- standalone: every send counts
        END AS customer_count
    FROM valid_campaigns vc
    JOIN is_chain ic ON ic.root_id = vc.root_id
    JOIN communication_log cl ON cl.communication_id = vc.id
    GROUP BY vc.root_id, ic.chain_size
);
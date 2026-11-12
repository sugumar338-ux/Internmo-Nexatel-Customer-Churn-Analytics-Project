-- NexaTel Customer Churn Analytics Project
-- SQL analysis template (SQLite 3.25+ / compatible with minor dialect adjustments)
-- Import the six CSVs into tables using the exact names below:
-- subscriptions, usage_voice, usage_sms, usage_data, support_tickets, stores.
-- Dates in source files are DD-MM-YYYY; usage_month is MM-YYYY.
-- Important: the supplied files do not include demographics, payment history,
-- a plan catalogue, or a customer-to-store mapping.

-- 1) Latest subscription row per customer (window function)
WITH ranked_subscriptions AS (
    SELECT s.*,
           ROW_NUMBER() OVER (
               PARTITION BY customer_id
               ORDER BY
                 substr(start_date, 7, 4) || '-' ||
                 substr(start_date, 4, 2) || '-' ||
                 substr(start_date, 1, 2) DESC,
                 subscription_id DESC
           ) AS rn
    FROM subscriptions s
),
latest_subscription AS (
    SELECT * FROM ranked_subscriptions WHERE rn = 1
)
SELECT subscription_status, COUNT(DISTINCT customer_id) AS customers,
       ROUND(SUM(monthly_charge_inr), 2) AS monthly_charge_total_inr,
       ROUND(AVG(monthly_charge_inr), 2) AS avg_monthly_charge_inr
FROM latest_subscription
GROUP BY subscription_status
ORDER BY customers DESC;

-- 2) Customer-level churn KPI (UNKNOWN_STATE excluded from denominator)
WITH ranked AS (
    SELECT *,
           ROW_NUMBER() OVER (
             PARTITION BY customer_id
             ORDER BY
               substr(start_date, 7, 4) || '-' ||
               substr(start_date, 4, 2) || '-' ||
               substr(start_date, 1, 2) DESC,
               subscription_id DESC
           ) rn
    FROM subscriptions
),
latest AS (SELECT * FROM ranked WHERE rn = 1)
SELECT
    COUNT(*) AS unique_customers,
    SUM(CASE WHEN subscription_status = 'Terminated' THEN 1 ELSE 0 END) AS churned_customers,
    SUM(CASE WHEN subscription_status = 'Active' THEN 1 ELSE 0 END) AS active_customers,
    SUM(CASE WHEN subscription_status = 'UNKNOWN_STATE' THEN 1 ELSE 0 END) AS unknown_status_customers,
    ROUND(
      100.0 * SUM(CASE WHEN subscription_status = 'Terminated' THEN 1 ELSE 0 END) /
      NULLIF(SUM(CASE WHEN subscription_status IN ('Active','Terminated') THEN 1 ELSE 0 END), 0),
      2
    ) AS observed_churn_rate_pct
FROM latest;

-- 3) Support ticket metrics by customer, joined to latest subscription
WITH ranked AS (
    SELECT *, ROW_NUMBER() OVER (
        PARTITION BY customer_id
        ORDER BY
          substr(start_date, 7, 4) || '-' ||
          substr(start_date, 4, 2) || '-' ||
          substr(start_date, 1, 2) DESC,
          subscription_id DESC
    ) rn
    FROM subscriptions
),
latest AS (SELECT * FROM ranked WHERE rn = 1),
ticket_summary AS (
    SELECT customer_id, COUNT(*) AS ticket_count,
           SUM(CASE WHEN status='Pending' THEN 1 ELSE 0 END) AS pending_tickets,
           SUM(CASE WHEN status='Escalated' THEN 1 ELSE 0 END) AS escalated_tickets,
           SUM(CASE WHEN status='Reopened' THEN 1 ELSE 0 END) AS reopened_tickets,
           SUM(CASE WHEN status='Resolved' THEN 1 ELSE 0 END) AS resolved_tickets
    FROM support_tickets
    GROUP BY customer_id
)
SELECT l.customer_id, l.subscription_status, l.monthly_charge_inr,
       COALESCE(t.ticket_count,0) AS ticket_count,
       COALESCE(t.pending_tickets,0) AS pending_tickets,
       COALESCE(t.escalated_tickets,0) AS escalated_tickets,
       COALESCE(t.reopened_tickets,0) AS reopened_tickets
FROM latest l
LEFT JOIN ticket_summary t ON l.customer_id = t.customer_id;

-- 4) Churn rate by support-contact frequency
WITH ranked AS (
    SELECT *, ROW_NUMBER() OVER (
        PARTITION BY customer_id
        ORDER BY
          substr(start_date, 7, 4) || '-' ||
          substr(start_date, 4, 2) || '-' ||
          substr(start_date, 1, 2) DESC,
          subscription_id DESC
    ) rn
    FROM subscriptions
),
latest AS (SELECT * FROM ranked WHERE rn = 1),
ticket_count AS (
    SELECT customer_id, COUNT(*) AS n_tickets
    FROM support_tickets GROUP BY customer_id
),
joined AS (
    SELECT l.customer_id, l.subscription_status,
           COALESCE(t.n_tickets,0) AS n_tickets
    FROM latest l LEFT JOIN ticket_count t USING(customer_id)
)
SELECT
    CASE
      WHEN n_tickets = 0 THEN '0 tickets'
      WHEN n_tickets = 1 THEN '1 ticket'
      WHEN n_tickets = 2 THEN '2 tickets'
      WHEN n_tickets = 3 THEN '3 tickets'
      WHEN n_tickets BETWEEN 4 AND 5 THEN '4-5 tickets'
      ELSE '6+ tickets'
    END AS ticket_band,
    COUNT(*) AS customers,
    SUM(CASE WHEN subscription_status='Terminated' THEN 1 ELSE 0 END) AS terminated_customers,
    ROUND(100.0 * SUM(CASE WHEN subscription_status='Terminated' THEN 1 ELSE 0 END) /
      NULLIF(SUM(CASE WHEN subscription_status IN ('Active','Terminated') THEN 1 ELSE 0 END),0),2)
      AS observed_churn_rate_pct
FROM joined
WHERE subscription_status IN ('Active','Terminated')
GROUP BY ticket_band
ORDER BY customers DESC;

-- 5) Monthly usage trends
SELECT usage_month,
       ROUND(AVG(voice_minutes_used),2) AS avg_voice_minutes,
       COUNT(DISTINCT customer_id) AS customers
FROM usage_voice
GROUP BY usage_month
ORDER BY substr(usage_month,4,4)||'-'||substr(usage_month,1,2);

SELECT usage_month,
       ROUND(AVG(data_gb_used),2) AS avg_data_gb,
       ROUND(
         AVG(data_gb_used),2
       ) AS mean_data_gb,
       COUNT(*) AS usage_rows
FROM usage_data
GROUP BY usage_month
ORDER BY substr(usage_month,4,4)||'-'||substr(usage_month,1,2);

-- 6) Revenue proxy: recorded monthly charges associated with latest terminated status.
-- This is NOT verified MRR lost unless monthly_charge_inr is a current recurring
-- price and termination timing/billing status are validated.
WITH ranked AS (
    SELECT *, ROW_NUMBER() OVER (
        PARTITION BY customer_id
        ORDER BY
          substr(start_date, 7, 4) || '-' ||
          substr(start_date, 4, 2) || '-' ||
          substr(start_date, 1, 2) DESC,
          subscription_id DESC
    ) rn
    FROM subscriptions
),
latest AS (SELECT * FROM ranked WHERE rn = 1)
SELECT
    ROUND(SUM(CASE WHEN subscription_status='Terminated' THEN monthly_charge_inr ELSE 0 END),2)
      AS terminated_customer_monthly_charge_proxy_inr,
    ROUND(SUM(CASE WHEN subscription_status='Active' THEN monthly_charge_inr ELSE 0 END),2)
      AS active_customer_monthly_charge_proxy_inr
FROM latest;

-- 7) Usage change by customer (Q1 2026; descriptive only)
WITH usage_pivot AS (
    SELECT customer_id,
       MAX(CASE WHEN usage_month='01-2026' THEN data_gb_used END) AS jan_data_gb,
       MAX(CASE WHEN usage_month='02-2026' THEN data_gb_used END) AS feb_data_gb,
       MAX(CASE WHEN usage_month='03-2026' THEN data_gb_used END) AS mar_data_gb
    FROM usage_data
    GROUP BY customer_id
)
SELECT customer_id, jan_data_gb, feb_data_gb, mar_data_gb,
       ROUND(mar_data_gb - jan_data_gb,2) AS jan_to_mar_change_gb
FROM usage_pivot;

-- 8) Data quality: missing plan IDs and unknown subscription states
SELECT
  SUM(CASE WHEN plan_id IS NULL OR TRIM(plan_id)='' THEN 1 ELSE 0 END) AS missing_plan_id_rows,
  SUM(CASE WHEN subscription_status='UNKNOWN_STATE' THEN 1 ELSE 0 END) AS unknown_state_rows
FROM subscriptions;

-- 9) Store master profile (cannot be connected to churn without customer-store key)
SELECT region_id, state_id, COUNT(*) AS store_count
FROM stores
GROUP BY region_id, state_id
ORDER BY store_count DESC;

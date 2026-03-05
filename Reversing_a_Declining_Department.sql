/*
Project: Reversing a Declining Department
Objective: To perform a diagnostic analysis of a 1.6M monthly revenue decline and model the ROI of potential solutions.
Dialect: SQLite

Query 1: Trend Analysis
Query 2: Trend and Volatility Analysis (PostgreSQL)
Query 3: Weekly Revenue and Engagement Decay Analysis
Query 4: User Segmentation - Identifying the Target Market
Query 5: Profit Margin and Product Mix Analysis
Query 6: Simulating a Reward Structure and Loss Range
Query 7: User Behavioral Analysis
Query 8: Why the Cashback Model was Rejected
 */

/* ---------- Query 1: Trend Analysis ----------
===== Business Question: =====
Is the gambling wager total declining each month?
 */
WITH calc_first_month AS (
-- Finds the first month that gambling started
	SELECT
		MIN(strftime('%Y-%m-01', date)) AS first_month
	FROM death_rolls -- only 1 table because all gambling except lottery introduced at the same time
)
SELECT
-- Calculates the total amount wagered for each month
	strftime('%Y-%m-01', t.date) AS month,
	SUM(t.wager) wager_total
FROM (
	-- Gambling Section: Death Rolls
	SELECT wager * 2 AS wager, date FROM death_rolls WHERE lockedIn = 'T' -- x2 because each row in death_rolls table has both the winner and loser with only 1 person's wager
	UNION ALL
	-- Gambling Section: Dice Duels
	SELECT wager * 2 AS wager, date FROM dice_duels WHERE lockedIn = 'T' -- x2 because each row in dice_duels table has both the winner and loser with only 1 person's wager
	UNION ALL
	-- Gambling Section: Over/Under
	SELECT wager, date FROM over_under
	UNION ALL
	-- Gambling Section: Lottery
	SELECT
		le.quantity * l.ticketPrice,
		le.date
	FROM lottery_entries le
	LEFT JOIN lotteries l ON l.id = le.lottoId
) t
CROSS JOIN calc_first_month cfm
WHERE month >= cfm.first_month
GROUP BY month
/*
===== Interpretation: =====
After inputting the month and wager_total result table into google sheets to create a quick trend line, we can see that there is a significant visual decline.
Even after excluding the first month launch with a massive total wager, the line visibly trends down from approximately 6.5M to 3M, and seems to justify examining
how strong of a correlation the sales and time is.

===== Business Recommendation: =====
Perform a linear regression to find the slope and r-squared.
*/

/* ---------- Query 2: Trend and Volatility Analysis (PostgreSQL) ----------
Important!!! This query will not run in SQLite. SQLite does not natively support Linear Regression so PostgreSQL was used.

===== Business Question: =====
How significant is the downtrend and how much is the business losing in sales month over month?
 */
WITH calc_first_month AS (
-- Finds the first month that gambling started
	SELECT
		MIN(DATE_TRUNC('month', date::TIMESTAMP)) AS first_month
	FROM death_rolls -- only 1 table because all gambling except lottery introduced at the same time
),
calc_monthly_total_wager AS (
	SELECT
	-- Calculates the total amount wagered for each month
		DATE_TRUNC('month', date::TIMESTAMP)::DATE AS month,
		SUM(t.wager) wager_total
	FROM (
		-- Gambling Section: Death Rolls
		SELECT wager * 2 AS wager, date FROM death_rolls WHERE lockedIn = 'T' -- x2 because each row in death_rolls table has both the winner and loser with only 1 person's wager
		UNION ALL
		-- Gambling Section: Dice Duels
		SELECT wager * 2 AS wager, date FROM dice_duels WHERE lockedIn = 'T' -- x2 because each row in dice_duels table has both the winner and loser with only 1 person's wager
		UNION ALL
		-- Gambling Section: Over/Under
		SELECT wager, date FROM over_under
		UNION ALL
		-- Gambling Section: Lottery
		SELECT
			le.quantity * l.ticketPrice,
			le.date
		FROM lottery_entries le
		LEFT JOIN lotteries l ON l.id = le.lottoId
	) t	
	CROSS JOIN calc_first_month cfm
	WHERE DATE_TRUNC('month', date::TIMESTAMP) >= cfm.first_month
	GROUP BY month
	ORDER BY month
	OFFSET 1 -- Tossing first month since launch month produced more than 3x the total wager as the following month.
),
calc_rn AS (
-- Calculates a row number to be able to create a trend line
	SELECT
		wager_total,
		ROW_NUMBER() OVER (ORDER BY month) as rn
	FROM calc_monthly_total_wager
)
-- Main query performs a linear regression analysis
SELECT
	ROUND(regr_slope(wager_total, rn)) AS trend_slope,
	ROUND(regr_intercept(wager_total, rn)) AS y_intercept,
	ROUND(regr_r2(wager_total, rn)::NUMERIC, 4) AS r_squared,
	ROUND(AVG(wager_total)) AS avg_monthly_wager
FROM calc_rn
/*
===== Interpretation: =====
The y-intercept is 64.9M and the trend slope is -1.6M meaning that the business is trending downwards with a start of 64.9M and losing approximately 1.6M in sales each month compared
to the previous month. The r-squared is .1828 and since this is less than .3, time is not a large factor in the trend.

===== Business Recommendation: =====
In order to improve the gambling wager total, the business should examine who the highest spenders are to know who to target.
*/

/* ---------- Query 3: Weekly Revenue and Engagement Decay Analysis ----------
===== Premise: =====
The Business has identified that gambling sales are down. So now the business needs to know how fast is it dropping and whether it is total wager or user count.

===== Business Question: =====
For gambling user count and gambling total wager, how long have they been downtrending, at what rate, and what is the decay amount relative to the most recent peak?

===== Expected Query Results: =====
For each of: gambling user count and gambling total wager, return the number of weeks it has been downtrending, average loss (# of users or total wager)
in the current streak, and the % remaining each week of the streak.
*/
WITH create_sales_table AS (
-- Combines all sales tables into 1 master table where the run was confirmed
	SELECT member, cut FROM balance_legacy WHERE confirmed = 'T'
	UNION ALL
	SELECT member, cut FROM balance_m_plus WHERE confirmed = 'T'
	UNION ALL
	SELECT member, cut FROM balance_mount WHERE confirmed = 'T'
	UNION ALL
	SELECT member, cut FROM balance_other WHERE confirmed = 'T'
	UNION ALL
	SELECT member, cut FROM balance_pvp WHERE confirmed = 'T'
	UNION ALL
	SELECT member, cut FROM balance_raid WHERE confirmed = 'T'
	UNION ALL
	SELECT member, cut FROM ad_cuts -- ad_cuts table does not have a confirmed column since sales are final
),
calc_decile AS (
-- Calculates totals from every member
	SELECT
		t.member,
		NTILE(10) OVER (ORDER BY t.member_income) AS decile -- Calculates NTILEs for lifetime income because it is nearly all disposable permanently.
	FROM (
	-- Sums cut totals for each member
		SELECT
			member,
			SUM(cut) AS member_income
		FROM create_sales_table
		GROUP BY member
	) t
),
calc_total_wager AS (
-- Calculates the total wager for all games per member and per day
	SELECT
		t.member,
		DATE(t.date, 'weekday 2', '-7 days') AS week, -- Business Week starts on Tuesday
		SUM(ABS(t.wager)) AS total_wager
	FROM (
		-- Gambling Section: Death Rolls
		SELECT starter AS member, wager, date FROM death_rolls WHERE lockedIn = 'T'
		UNION ALL
		SELECT defender AS member, wager, date FROM death_rolls WHERE lockedIn = 'T'
		UNION ALL
		-- Gambling Section: Dice Duels
		SELECT starter AS member, wager, date FROM dice_duels WHERE lockedIn = 'T'
		UNION ALL
		SELECT defender AS member, wager, date FROM dice_duels WHERE lockedIn = 'T'
		UNION ALL
		-- Gambling Section: Over/Under
		SELECT member, wager, date FROM over_under
		UNION ALL
		-- Gambling Section: Lottery
		SELECT
			le.member,
			le.quantity * l.ticketPrice,
			le.date
		FROM lottery_entries le
		LEFT JOIN lotteries l ON l.id = le.lottoId
	) t
	WHERE EXISTS (SELECT 1 FROM calc_decile cd WHERE cd.member = t.member AND cd.decile = 10)
	GROUP BY week, t.member
),
calc_week_grain AS (
	SELECT
		week,
		SUM(total_wager) AS wager_total,
		COUNT(member) AS member_count
	FROM calc_total_wager
	GROUP BY week
),
calc_does_drop AS (
-- 0/1 is downtrending from previous week
	SELECT
		week,
		wager_total,
		CASE
			WHEN LAG(wager_total) OVER (ORDER BY week) > wager_total THEN 1
			ELSE 0
		END AS streak_change_wager,
		member_count,
		CASE
			WHEN LAG(member_count) OVER (ORDER BY week) > member_count THEN 1
			ELSE 0
		END AS streak_change_member
	FROM calc_week_grain
),
calc_streak_start AS (
-- 0/1 is start of streak
	SELECT
		week,
		wager_total,
		streak_change_wager,
		CASE
			WHEN LAG(streak_change_wager) OVER (ORDER BY week) <> streak_change_wager AND streak_change_wager = 1 THEN 1
			ELSE 0
		END AS streak_start_wager,
		member_count,
		streak_change_member,
		CASE
			WHEN LAG(streak_change_member) OVER (ORDER BY week) <> streak_change_member AND streak_change_member = 1 THEN 1
			ELSE 0
		END AS streak_start_member
	FROM calc_does_drop
),
calc_streak_id AS (
-- creates a unique id for each streak
	SELECT
		week,
		wager_total,
		streak_change_wager,
		streak_start_wager,
		CASE
			WHEN streak_change_wager = 1 THEN SUM(streak_start_wager) OVER (ORDER BY week)
			ELSE 0
		END AS streak_id_wager,
		member_count,
		streak_change_member,
		streak_start_member,
		CASE
			WHEN streak_change_member = 1 THEN SUM(streak_start_member) OVER (ORDER BY week)
			ELSE 0
		END AS streak_id_member
	FROM calc_streak_start
),
calc_streak_length AS (
-- Find the length of the streak
	SELECT
		week,
		wager_total,
		streak_change_wager,
		streak_start_wager,
		streak_id_wager,
		CASE
			WHEN streak_id_wager > 0 THEN COUNT(*) OVER (PARTITION BY streak_id_wager ORDER BY week)
			ELSE 0
		END AS streak_length_wager,
		member_count,
		streak_change_member,
		streak_start_member,
		streak_id_member,
		CASE
			WHEN streak_id_member > 0 THEN COUNT(*) OVER (PARTITION BY streak_id_member ORDER BY week)
			ELSE 0
		END AS streak_length_member
	FROM calc_streak_id
),
calc_previous_peak AS (
-- Find the most recent peak before the downtrend started
	SELECT
		week,
		wager_total,
		streak_change_wager,
		streak_start_wager,
		streak_id_wager,
		streak_length_wager,
		CASE
			-- IFNULL() not needed because streak_change_wager cannot be 1 on the first week, so the LAG() will not return a NULL
			WHEN streak_change_wager = 1 THEN LAG(wager_total, streak_length_wager) OVER (ORDER BY week)
			ELSE 0
		END AS streak_start_total_wager,
		CASE
			WHEN streak_change_wager = 1 THEN MIN(wager_total) OVER (PARTITION BY streak_id_wager)
			ELSE 0
		END AS streak_min_wager,
		member_count,
		streak_change_member,
		streak_start_member,
		streak_id_member,
		streak_length_member,
		CASE
			-- IFNULL() not needed because streak_change_wager cannot be 1 on the first week, so the LAG() will not return a NULL
			WHEN streak_change_member = 1 THEN LAG(member_count, streak_length_member) OVER (ORDER BY week) 
			ELSE 0
		END AS streak_member_count_start,
		CASE
			WHEN streak_change_member = 1 THEN MIN(member_count) OVER (PARTITION BY streak_id_member)
			ELSE 0
		END AS streak_min_member
	FROM calc_streak_length
),
calc_streak_avg AS (
-- Find the average drop from week to week for each streak.
	SELECT
		week,
		wager_total,
		streak_change_wager,
		streak_start_wager,
		streak_id_wager,
		streak_length_wager,
		streak_start_total_wager,
		streak_min_wager,
		-- If changing final select to all weeks of recent streak, change ↓↓↓ streak_length_wager ↓↓↓ to a MAX() window
		ROUND(1.0 * (streak_start_total_wager - streak_min_wager) / NULLIF(streak_length_wager, 0)) AS streak_avg_wager,
		-- NULLIF() added for data integrity even though a streak shouldn't be able to start on a 0
		ROUND(100.0 * wager_total / NULLIF(streak_start_total_wager, 0)) AS streak_percent_drop_wager,
		member_count,
		streak_change_member,
		streak_start_member,
		streak_id_member,
		streak_length_member,
		streak_member_count_start,
		streak_min_member,
		-- If changing final select to all weeks of recent streak, change ↓↓↓ streak_length_member ↓↓↓ to a MAX() window
		ROUND(1.0 * (streak_member_count_start - streak_min_member) / NULLIF(streak_length_member, 0)) AS streak_avg_member,
		-- NULLIF() added for data integrity even though a streak shouldn't be able to start on a 0
		ROUND(100.0 * member_count / NULLIF(streak_member_count_start, 0)) AS streak_percent_drop_member
	FROM calc_previous_peak
),
calc_current_week AS (
-- Find current week
	SELECT
		MAX(week) AS current_week
	FROM calc_total_wager
),
perform_concatenation_wager AS (
-- Creates a text sparkline for wager drop percents
	SELECT
		streak_id_wager,
		'100 > ' || GROUP_CONCAT(CAST(streak_percent_drop_wager AS INT), ' > ') || '%' AS percent_drop_concat_wager
	FROM (
        SELECT * FROM calc_streak_avg 
        WHERE streak_id_wager > 0
        ORDER BY week ASC
    )
	GROUP BY streak_id_wager
),
perform_concatenation_member AS (
-- Creates a text sparkline for member drop percents
	SELECT
		streak_id_member,
		'100 > ' || GROUP_CONCAT(CAST(streak_percent_drop_member AS INT), ' > ') || '%' AS percent_drop_concat_member
	FROM (
        SELECT * FROM calc_streak_avg 
        WHERE streak_id_member > 0
        ORDER BY week ASC
    )
	GROUP BY streak_id_member
)
-- Main query compiles a report
SELECT
	'Current Downtrend:' AS '',
	'Total Wager:' AS Category,
	streak_length_wager AS weeks,
	-streak_avg_wager AS avg_drop,
	pcw.percent_drop_concat_wager AS sparkline
FROM calc_streak_avg csa
CROSS JOIN calc_current_week ccw
LEFT JOIN perform_concatenation_wager pcw ON pcw.streak_id_wager = csa.streak_id_wager
WHERE week = ccw.current_week
UNION ALL
SELECT
	'Current Downtrend:' AS '',
	'User Count:' AS Category,
	streak_length_member AS weeks,
	-streak_avg_member AS avg_drop,
	pcm.percent_drop_concat_member AS sparkline
FROM calc_streak_avg csa
CROSS JOIN calc_current_week ccw
LEFT JOIN perform_concatenation_member pcm ON pcm.streak_id_member = csa.streak_id_member
WHERE week = ccw.current_week
UNION ALL
SELECT '', '', '', '', ''
UNION ALL
SELECT 'Week:', 'Total Wager:', 'Change', 'Member Count:', 'Change'
UNION ALL
SELECT
	*
FROM (
	SELECT
		week,
		100000 * ROUND(wager_total / 100000),
		100000 * ROUND(wager_total / 100000) - 100000 * ROUND(LAG(wager_total) OVER (ORDER BY week) / 100000),
		member_count,
		member_count - LAG(member_count) OVER (ORDER BY week)
	FROM calc_streak_avg
	ORDER BY week DESC -- Return the final weeks
	LIMIT 10 -- Show last 10 weeks
) t
/*
===== Interpretation: =====
It is worth noting that the data's last date is Tuesday December 18, 2025. This means that the final week is represented by a single day and therefore the last week should not be
taken into consideration. Currently, we can see that both the total wager and user count have been downtrending for a week, and both with a high rate of drop week over week at 59%
and 33%. Since the wager total has historic large swings, this one week downswing is not necessarily a large issue by itself.

===== Business Recommendation: =====
This query was mainly written for periodic checks by the department lead as an early-warning reactive measure for checking whether gambling has been down recently.
*/

/* ---------- Query 4: User Segmentation - Identifying the Target Market ----------
===== Premise: ======
The business has identified that it is leaking both users and total wagers, so it now needs to know which segment is responsible for the drop.

===== Business Question: =====
Due to a declining gambling trend, how much are the top users spending of their disposable income on gambling?

===== Expected Query Results: =====
For each decile of user's income, what percent of their income is being spent on gambling.
*/
WITH calc_gambling AS (
-- Calculates wager total per member for all games
	SELECT
		member,
		SUM(wager) wager_total
	FROM (
		-- Gambling Section: Death Rolls
		SELECT starter AS member, wager FROM death_rolls WHERE lockedIn = 'T'
		UNION ALL
		SELECT defender AS member, wager FROM death_rolls WHERE lockedIn = 'T'
		UNION ALL
		-- Gambling Section: Dice Duels
		SELECT starter AS member, wager FROM dice_duels WHERE lockedIn = 'T'
		UNION ALL
		SELECT defender AS member, wager FROM dice_duels WHERE lockedIn = 'T'
		UNION ALL
		-- Gambling Section: Over/Under
		SELECT member, wager FROM over_under
		UNION ALL
		-- Gambling Section: Lottery
		SELECT
			le.member,
			le.quantity * l.ticketPrice
		FROM lottery_entries le
		LEFT JOIN lotteries l ON l.id = le.lottoId
	) t
	GROUP BY member
),
create_sales_table AS (
-- Combines all sales tables into 1 master table where the run was confirmed
	SELECT 'legacy' AS dept, member, cut, cutType FROM balance_legacy WHERE confirmed = 'T'
	UNION ALL
	SELECT 'mplus' AS dept, member, cut, cutType FROM balance_m_plus WHERE confirmed = 'T'
	UNION ALL
	SELECT 'mount' AS dept, member, cut, cutType FROM balance_mount WHERE confirmed = 'T'
	UNION ALL
	SELECT 'other' AS dept, member, cut, cutType FROM balance_other WHERE confirmed = 'T'
	UNION ALL
	SELECT 'pvp' AS dept, member, cut, cutType FROM balance_pvp WHERE confirmed = 'T'
	UNION ALL
	SELECT 'raid' AS dept, member, cut, 'boost' AS cutType FROM balance_raid WHERE confirmed = 'T'
	UNION ALL
	SELECT 'raid' AS dept, member, cut, cutType FROM ad_cuts -- ad_cuts table does not have a confirmed column since sales are final
),
calc_income AS (
-- Calculates totals from every member for every department and advertiser/booster
-- Chose to make CTE informative rather than minimalist for reusability
	SELECT
		t.member,
		b_legacy + b_mplus + b_mount + b_other + b_pvp + b_raid
			+ ad_legacy + ad_mplus + ad_mount + ad_other + ad_pvp + ad_raid AS primary_income,
		-- NTILE acceptable because user count in the thousands
		NTILE(10) OVER (
			ORDER BY b_legacy + b_mplus + b_mount + b_other + b_pvp + b_raid
			+ ad_legacy + ad_mplus + ad_mount + ad_other + ad_pvp + ad_raid
		) AS decile,
		b_legacy,
		b_mplus,
		b_mount,
		b_other,
		b_pvp,
		b_raid,
		b_legacy + b_mplus + b_mount + b_other + b_pvp + b_raid AS b_total,
		ad_legacy,
		ad_mplus,
		ad_mount,
		ad_other,
		ad_pvp, 
		ad_raid,
		ad_legacy + ad_mplus + ad_mount + ad_other + ad_pvp + ad_raid AS ad_total
	FROM (
	-- Sums cut totals for each member
	-- Subquery used to get around referencing an alias in the same select or to prevent a massive sum of a sum of a case
		SELECT
			member,
			--calculate booster income for each dept
			SUM(CASE WHEN cutType = 'boost' AND dept = 'legacy' THEN cut ELSE 0 END) b_legacy,
			SUM(CASE WHEN cutType = 'boost' AND dept = 'mplus' THEN cut ELSE 0 END) b_mplus,
			SUM(CASE WHEN cutType = 'boost' AND dept = 'mount' THEN cut ELSE 0 END) b_mount,
			SUM(CASE WHEN cutType = 'boost' AND dept = 'other' THEN cut ELSE 0 END) b_other,
			SUM(CASE WHEN cutType = 'boost' AND dept = 'pvp' THEN cut ELSE 0 END) b_pvp,
			SUM(CASE WHEN cutType = 'boost' AND dept = 'raid' THEN cut ELSE 0 END) b_raid,
			-- calculate ad income for each dept
			SUM(CASE WHEN cutType = 'ad' AND dept = 'legacy' THEN cut ELSE 0 END) ad_legacy,
			SUM(CASE WHEN cutType = 'ad' AND dept = 'mplus' THEN cut ELSE 0 END) ad_mplus,
			SUM(CASE WHEN cutType = 'ad' AND dept = 'mount' THEN cut ELSE 0 END) ad_mount,
			SUM(CASE WHEN cutType = 'ad' AND dept = 'other' THEN cut ELSE 0 END) ad_other,
			SUM(CASE WHEN cutType = 'ad' AND dept = 'pvp' THEN cut ELSE 0 END) ad_pvp,
			SUM(CASE WHEN cutType = 'ad' AND dept = 'raid' THEN cut ELSE 0 END) ad_raid
		FROM create_sales_table
		GROUP BY member
	) t
),
calc_percentile AS (
-- Calculates the income and wager_total per decile
	SELECT
		decile,
		SUM(ci.primary_income) AS decile_income,
		SUM(cg.wager_total) AS decile_gambling,
		COALESCE(ROUND(100.0 * SUM(cg.wager_total) / SUM(ci.primary_income),1), 0) AS percent
	FROM calc_income ci
	-- LEFT JOIN used because business rule forces a user to have a balance from primary income in order to gamble
	LEFT JOIN calc_gambling cg ON ci.member = cg.member
	GROUP BY decile
)
SELECT -- Adds a cumulative sum to each decile
	*,
	SUM(decile_gambling) OVER (ORDER BY decile ASC) AS cumulative
FROM calc_percentile
ORDER BY decile DESC
/*
===== Interpretation: =====
The top decile of earners gamble 7x as much as the other 90% combined while also making 3.4x as much as the other 90% combined. This means that the
wealth is extremely concentrated in the top 10% and they show how disposable it is by gambling significantly more than the rest of the population.

===== Recommendation: =====
The marketplace should provide greater incentives and targeted days that require a minimum total wager amount or minimum number of wagers that
will incentivize the top earners to gamble in order to hit reward tiers. Additionally, the business could offer cashbacks or small incentives
to the largest losers to increase low morale after a loss. This will allow the business to generate more passive income (gambling income) and
thereby increase its profitability.
*/

/* ---------- Query 5: Profit Margin and Product Mix Analysis ----------
===== Premise: =====
The goal is profitability, so we need to find the community profit to know how much we can afford to reward users.

===== Business Question: =====
For each month and as a total, what is the community profit as a percent?

===== Expected Query Results: =====
For the overall and every month, list the total margin and profit as well as the per-game profit.
*/
WITH RECURSIVE month_spine(month) AS (
-- Added monthly spine to ensure any months with no gambling are included
	SELECT '2023-11-01' -- Lottery start date; gambling started later
	UNION ALL
	SELECT DATE(month, '+1 month') FROM month_spine
	WHERE month < DATE('now', 'start of month')
),
calc_lottery AS (
-- Calculates total and profit margin of the Lottery
	SELECT
		strftime('%Y-%m-01', l.drawDate) AS month,
		l.ticketPrice * SUM(le.quantity) AS total,
		ROUND(l.ticketPrice * SUM(le.quantity) * .025) AS profit, -- 5% commission and engineer receives 2.5% of total lowering the profit margin to 2.5%
		2.5 AS profit_margin
	FROM lotteries l
	JOIN lottery_entries le ON l.id = le.lottoID
	WHERE l.drawn = 'T'
	GROUP BY month
),
calc_over_under AS (
-- Calculates total and profit margin of "Over/Under" game
	SELECT
		strftime('%Y-%m-01', date) AS month,
		SUM(wager) AS total,
		ROUND(SUM(-amountWon) * .75) AS profit, -- House cut is variable by chance and engineer receives 25% of profits
		ROUND(.75 * 100.0 * SUM(-amountWon) / SUM(wager), 1) AS profit_margin
	FROM over_under
	GROUP BY month
),
calc_dice_duels AS (
-- Calculates total and profit margin of "Dice Duels" game
	SELECT
		strftime('%Y-%m-01', date) AS month,
		SUM(wager * 2) AS total,
		ROUND(SUM(wager * 2) * .03) AS profit, -- 5% commission and engineer receives 2% of total lowering the profit margin to 3%
		3 AS profit_margin
	FROM dice_duels
	WHERE lockedIn = 'T'
	GROUP BY month
),
calc_death_rolls AS (
-- Calculates total and profit margin of "Death Rolls" game
	SELECT
		strftime('%Y-%m-01', date) AS month,
		SUM(wager * 2) AS total,
		ROUND(SUM(wager * 2) * .03) AS profit, -- 5% commission and engineer receives 2% of total lowering the profit margin to 3%
		3 AS profit_margin
	FROM death_rolls
	WHERE lockedIn = 'T'
	GROUP BY month
),
calc_overall AS (
-- Calculates the overall total to make it easier to read in the main query
	SELECT
		SUM(cl.total) + SUM(cou.total) + SUM(cdd.total) + SUM(cdr.total) AS gambling_total, -- Product Yield
		SUM(cl.total) AS lottery_total,
		SUM(cou.total) AS overunder_total,
		SUM(cdd.total) AS dice_total,
		SUM(cdr.total) AS death_roll_total,
		SUM(cl.profit) + SUM(cou.profit) + SUM(cdd.profit) + SUM(cdr.profit) AS total_profit, -- Profit
		SUM(cl.profit) AS lottery_profit,
		SUM(cou.profit) AS overunder_profit,
		SUM(cdd.profit) AS dice_profit,
		SUM(cdr.profit) AS death_profit
	FROM month_spine ms
	LEFT JOIN calc_lottery cl ON cl.month = ms.month
	LEFT JOIN calc_over_under cou ON cou.month = ms.month
	LEFT JOIN calc_dice_duels cdd ON cdd.month = ms.month
	LEFT JOIN calc_death_rolls cdr ON cdr.month = ms.month
)
SELECT
	'Overall' AS month,
	ROUND(100.0 * total_profit / NULLIF(gambling_total, 0), 1) AS total_margin,
	total_profit,
	lottery_profit,
	overunder_profit,
	dice_profit,
	death_profit
FROM calc_overall
UNION ALL
SELECT
	ms.month,
	COALESCE(ROUND(100.0 *
		(
			COALESCE(cl.profit, 0) +
			COALESCE(cou.profit, 0) + 
			COALESCE(cdd.profit, 0) + 
			COALESCE(cdr.profit, 0)
		) / NULLIF((
			COALESCE(cl.total, 0) + 
			COALESCE(cou.total, 0) + 
			COALESCE(cdd.total, 0) + 
			COALESCE(cdr.total, 0)
		), 0)
	, 1), 0) AS total_margin,
	COALESCE(cl.profit, 0) + COALESCE(cou.profit, 0) + COALESCE(cdd.profit, 0) + COALESCE(cdr.profit, 0) AS total_profit,
	COALESCE(cl.profit, 0) AS lottery_profit,
	COALESCE(cou.profit, 0) AS overunder_profit,
	COALESCE(cdd.profit, 0) AS dice_profit,
	COALESCE(cdr.profit, 0) AS death_profit
FROM month_spine ms
LEFT JOIN calc_lottery cl ON cl.month = ms.month
LEFT JOIN calc_over_under cou ON cou.month = ms.month
LEFT JOIN calc_dice_duels cdd ON cdd.month = ms.month
LEFT JOIN calc_death_rolls cdr ON cdr.month = ms.month
ORDER BY ms.month DESC
/*
===== Interpretation: =====
The trend likely jumps around because it is dependent on user choice of game play as opposed to active influence from the business. The overall
margin for gambling has been 8.3% which is likely attributed to more users not having friends to play with causing them to gravitate towards playing
against the house instead. This suggests that an increase in popularity in the gambling department will naturally cause more people to have an easier
time finding other people to play against and thus reduce the profit margins of the business. Therefore, the business should be aware and keep an eye on
the actual margins when implementing incentives for people to gamble more. The game (product) mix also shows that users tend to gravitate towards games
that take longer than just a few seconds, possibly due to wanting a larger dopamine hit from suspense instead of a game that instantly resolves.

===== Business Recommendation: =====
Implement a rewards program because there is a significant profit margin buffer. The business should ensure that the rewards program does not exceed the
theoretical minimum of 3% profit margin so that way even if the historical margin has been growing, the business keeps the department out of the red.
*/

/* ---------- Query 6: Simulating a Reward Structure and Loss Range ----------
===== Premise: =====
In order to stimulate the amount of gambling that the top decile does and offer rewards to frequent high rollers, add lottery tickets and a tiered
cashback in gambling targeting these users.

===== Business Question: =====
What is the expected loss if the gambling had been implemented 30 days ago for non-optimal (current) and optimal play (worst case for business)?
What is the necessary increase in gambling to break even?

===== Assumptions: =====
Due to prospect theory, users view lottery totals when deciding whether to purchase lottery tickets. Therefore, offering free lottery tickets to high
rollers will increase each week's lottery total and incentivizing all users to buy tickets. However, there is not enough data concentrated on user
behavior to accurately quantify the profit increase nor even to analyze whether prospect theory will play a small or large part. Many lotteries hosted
by the business struggle to gain traction and large lotteries are far and few between so the business needs more data to see a quantifiable change. The
expected ROI for quantifying the increase is too low given the lottery's modest contribution as a secondary income source.

===== Reward Logic: =====
Currently: After paying out the engineer cut, business currently earns a 8.3% cut on gambling with a theoretical minimum of 3%.
For every day, after a user gambles a total of 2.5M in a day, reward the user with a 25k gambling voucher, only redeemable on the following day.
For every day, if net loss is 1M+, reward the user with 1 lottery ticket worth 15k.
25k vouchers count toward the next day's total if used. No point in generating ill will over a negligible amount.

===== Expected Query Results: =====
Return the current play and worst case scenario if the rewards had been implemented 30 days ago with the current profit, cost of rewards,
expected profit, and required multiplier needed to break even.
*/
WITH input_variables AS (
-- Test output with different variable values
	SELECT
		30 AS days_before,
		2500000 AS wager_threshold,
		25000 AS gambling_voucher_cost,
		1000000 AS loss_threshold,
		15000 AS lottery_ticket_cost,
		.083 AS current_profit, -- Could bake the previous query's calculation into this one, but this gives flexibility to test changes in one spot
		.03 AS minimum_profit
),
calc_max_date AS (
-- Calculates the last day found in gambling. Change to DATE('now', '-30 days') instead of cross join if using live data
	SELECT
		MAX(date) AS max_date
	FROM (
		SELECT date FROM death_rolls
		UNION ALL
		SELECT date FROM dice_duels
		UNION ALL
		SELECT date FROM over_under
		UNION ALL
		SELECT date FROM lottery_entries
	) t
),
calc_date_before AS (
-- Calculates the number of days the query examines
	SELECT
		DATE(cmd.max_date, '-' || iv.days_before || ' days') AS date_before
	FROM calc_max_date cmd
	CROSS JOIN input_variables iv
),
calc_total_wager AS (
-- Calculates the total wager for all games per member and per day
	SELECT
		t.member,
		t.date,
		SUM(ABS(t.wager)) AS total_wager
	FROM (
		-- Gambling Section: Death Rolls
		SELECT starter AS member, wager, date FROM death_rolls WHERE lockedIn = 'T'
		UNION ALL
		SELECT defender AS member, wager, date FROM death_rolls WHERE lockedIn = 'T'
		UNION ALL
		-- Gambling Section: Dice Duels
		SELECT starter AS member, wager, date FROM dice_duels WHERE lockedIn = 'T'
		UNION ALL
		SELECT defender AS member, wager, date FROM dice_duels WHERE lockedIn = 'T'
		UNION ALL
		-- Gambling Section: Over/Under
		SELECT member, wager, date FROM over_under
		UNION ALL
		-- Gambling Section: Lottery
		SELECT
			le.member,
			le.quantity * l.ticketPrice,
			le.date
		FROM lottery_entries le
		LEFT JOIN lotteries l ON l.id = le.lottoId
	) t
	CROSS JOIN calc_date_before cdb
	WHERE t.date >= cdb.date_before
	GROUP BY t.date, t.member
),
calc_per_lottery AS (
-- Calculates totals per lottery
	SELECT
		t.id,
		DATE(l.drawDate) AS date,
		l.winner,
		l.secondwinner,
		t.total,
		l.drawn
	FROM (
		SELECT
			l.id,
			l.ticketPrice * SUM(le.quantity) AS total
		FROM lotteries l
		JOIN lottery_entries le ON l.id = le.lottoID
		GROUP BY l.id
	) t
	JOIN lotteries l ON l.id = t.id
),
calc_net_profit AS (
-- Calculates net profit from gambling per day per user
	SELECT
		t.member,
		t.date,
		SUM(t.net) AS net_profit
	FROM (
		-- Gambling Section: Death Rolls
		SELECT starter AS member, CASE WHEN starter = winner THEN wager * .95 ELSE -wager END AS net, date FROM death_rolls WHERE lockedIn = 'T'
		UNION ALL
		SELECT defender AS member, CASE WHEN defender = winner THEN wager * .95 ELSE -wager END AS net, date FROM death_rolls WHERE lockedIn = 'T'
		UNION ALL
		-- Gambling Section: Dice Duels
		SELECT starter AS member, CASE WHEN starter = winner THEN wager * .95 ELSE -wager END AS net, date FROM dice_duels WHERE lockedIn = 'T'
		UNION ALL
		SELECT defender AS member, CASE WHEN defender = winner THEN wager * .95 ELSE -wager END AS net, date FROM dice_duels WHERE lockedIn = 'T'
		UNION ALL
		-- Gambling Section: Over/Under
		SELECT member, amountWon AS net, date FROM over_under
		UNION ALL
		-- Gambling Section: Lottery.
		-- Using Cash Accounting because psychologically, a person receiving a windfall will be happier on the day they win and not need the ticket entry.
		SELECT le.member, -(le.quantity * l.ticketPrice), le.date FROM lottery_entries le LEFT JOIN lotteries l ON l.id = le.lottoId
		UNION ALL
		SELECT winner, total * .8 * .95, date FROM calc_per_lottery WHERE drawn = 'T' -- Big Winner receives 80% after 5% house commission
		UNION ALL
		SELECT secondwinner, total * .2 * .95, date FROM calc_per_lottery WHERE drawn = 'T' -- Small Winner receives 20% after 5% house commission
	) t
	CROSS JOIN calc_date_before cdb
	WHERE t.date >= cdb.date_before
	GROUP BY t.date, t.member
),
calc_last_30_total AS (
-- Calculates total wagers for all users over the last 30 days
	SELECT
		SUM(total_wager) AS last_30_total
	FROM calc_total_wager
),
calc_non_optimal_cost AS (
-- Calculates cost for non-optimal play. ie if this were implemented 30 days ago, what is the cost?
	SELECT
		iv.gambling_voucher_cost * SUM(FLOOR(ctw.total_wager / NULLIF(iv.wager_threshold, 0))) AS cost_vouchers_non,
		iv.lottery_ticket_cost * SUM(CASE WHEN cnp.net_profit <= -iv.loss_threshold THEN 1 ELSE 0 END) AS cost_tickets_non
	FROM calc_total_wager ctw
	JOIN calc_net_profit cnp ON ctw.member = cnp.member AND ctw.date = cnp.date
	CROSS JOIN input_variables iv
),
calc_optimal_cost AS (
-- Calculates the cost for optimal play.
	SELECT
		iv.gambling_voucher_cost * FLOOR(SUM(ctw.total_wager) / NULLIF(iv.wager_threshold, 0)) AS cost_vouchers_opt,
		iv.lottery_ticket_cost * FLOOR(SUM(ctw.total_wager) / NULLIF(iv.wager_threshold, 0) - 1) AS cost_tickets_opt -- Logically, you cannot give more tickets than vouchers
		-- All but 1 can lose. If everyone loses, it would by definition not be optimal because that means the house won it all
	FROM calc_total_wager ctw
	CROSS JOIN input_variables iv
)
SELECT
-- Players Do Not Change Strategy: Reports the profits and reward cost over the past 30 days assuming that players played as they had with no change
	'With Current Play:' AS category,
	ROUND(iv.current_profit * last_30_total) AS current_profit,
	cost_vouchers_non + cost_tickets_non AS cost, -- Assumes all vouchers are used
	ROUND(iv.current_profit * last_30_total - (cost_vouchers_non + cost_tickets_non)) AS profit_expected,
	ROUND((iv.current_profit * last_30_total) / (iv.current_profit * last_30_total - (cost_vouchers_non + cost_tickets_non)), 2) AS required_multiplier
FROM calc_non_optimal_cost
CROSS JOIN calc_last_30_total
CROSS JOIN input_variables iv
UNION ALL
SELECT
-- Systemic Worst Case: Profits and reward cost over the past 30 days if all players had played the lowest rake games and maximized their rewards
	'Absolute Worst Case:',
	ROUND(iv.minimum_profit * last_30_total) AS minimum_profit,
	cost_vouchers_opt + cost_tickets_opt AS cost_optimal, -- Assumes all vouchers are used
	ROUND(iv.minimum_profit * last_30_total - (cost_vouchers_opt + cost_tickets_opt)) AS profit_optimal,
	ROUND((iv.minimum_profit * last_30_total) / (iv.minimum_profit * last_30_total - (cost_vouchers_opt + cost_tickets_opt)), 2) AS required_multiplier
FROM calc_optimal_cost
CROSS JOIN calc_last_30_total
CROSS JOIN input_variables iv
/*
===== Interpretation: =====
The business would need to increase its sales between 1.06 and 1.97 times to justify the reward implementation. Worst Case is where all users play exactly
optimally and users only play against each other in low profit margin games. However, users will likely not play close to this. Many players will play only
slightly more optimally and a potential bonus to the lottery having a larger pool and incentivize other users. Furthermore, a daily voucher for high-rollers will heavily
encourage them to play the next day to use it instead of losing it. All daily vouchers not used are profit for the business.

===== Business Recommendation: =====
Implement the reward structure as in the reward logic above with the expected necessary increase to be slightly above 6%. Monitor the sales over the next month and possibly
phrase it as an experiment for 30 days to see if it becomes worthwhile. Ensure that the experiment moves past the honeymoon period. Any launch hype has historically been
concentrated in the first 7-14 days of any event in the business. It is reasonable to expect the third week to be the most balanced and closer to what we would expect the
actual profit change to show as it is not in the launch phase or in the closing week's last rush. As the event is launched and after it concludes, the business should closely
continue to analyze the week-by-week changes in profit margins and volume as well as the game mix to know if future events are likely to concentrate users in low margin games.
Also add VIP status roles with streaks or a threshold handled by the bot.
*/

/* ---------- Query 7: User Behavioral Analysis ----------
Important! Query abandoned, read the interpretation at the bottom.
===== Premise: =====
Users already have typical gambling patterns and the business needs to know if the proposed reward structure will actually produce meaningful increases to the department's
sales. Therefore, the business needs to know how often users are gambling at and close to the threshold. This is important because if only a tiny number of the top decile
gambles anywhere close to a total wager of 2.5M each day, the rewards program is unlikely to provide a long term uplift.

===== Business Question: =====
What percent of the top decile of income earners do not gamble and what percent regularly gamble <33% of the threshold, 33-66%, 67-99%, >= 100%?
Regularity is measured starting from their first day as: >= once a month, >= twice a month, >= once a week, >= twice a week

===== Expected Query Results: =====
Return a row with non-gambler %. Return a table of 4 rows with frequency and 4 columns with thresholds; each row should total 100% - non-gambler % because gambling amounts
per user are inconsistent.
*/
WITH input_variables AS (
-- Input reward threshold here.
	SELECT
		2500000 AS reward_threshold
),
calc_first_month AS (
-- Finds the first month that gambling started
	SELECT
		MIN(date) AS first_day
	FROM death_rolls -- only 1 table because all gambling except lottery introduced at the same time
),
create_sales_table AS (
-- Combines all sales tables into 1 master table where the run was confirmed
	SELECT member, cut FROM balance_legacy WHERE confirmed = 'T'
	UNION ALL
	SELECT member, cut FROM balance_m_plus WHERE confirmed = 'T'
	UNION ALL
	SELECT member, cut FROM balance_mount WHERE confirmed = 'T'
	UNION ALL
	SELECT member, cut FROM balance_other WHERE confirmed = 'T'
	UNION ALL
	SELECT member, cut FROM balance_pvp WHERE confirmed = 'T'
	UNION ALL
	SELECT member, cut FROM balance_raid WHERE confirmed = 'T'
	UNION ALL
	SELECT member, cut FROM ad_cuts -- ad_cuts table does not have a confirmed column since sales are final
),
calc_decile AS (
-- Calculates totals from every member
	SELECT
		t.member,
		NTILE(10) OVER (ORDER BY t.member_income) AS decile -- Calculates NTILEs for lifetime income because it is nearly all disposable permanently.
	FROM (
	-- Sums cut totals for each member
		SELECT
			member,
			SUM(cut) AS member_income
		FROM create_sales_table
		GROUP BY member
	) t
),
calc_user_daily_wager AS (
-- Calculates the total wager for all games per member and per week
	SELECT
		t.member,
		DATE(t.date, 'weekday 2', '-7 days') AS week, -- Business Week starts on Tuesday
		SUM(ABS(t.wager)) AS total_wager
	FROM (
		-- Gambling Section: Death Rolls
		SELECT starter AS member, wager, date FROM death_rolls WHERE lockedIn = 'T'
		UNION ALL
		SELECT defender AS member, wager, date FROM death_rolls WHERE lockedIn = 'T'
		UNION ALL
		-- Gambling Section: Dice Duels
		SELECT starter AS member, wager, date FROM dice_duels WHERE lockedIn = 'T'
		UNION ALL
		SELECT defender AS member, wager, date FROM dice_duels WHERE lockedIn = 'T'
		UNION ALL
		-- Gambling Section: Over/Under
		SELECT member, wager, date FROM over_under
		UNION ALL
		-- Gambling Section: Lottery
		SELECT
			le.member,
			le.quantity * l.ticketPrice,
			le.date
		FROM lottery_entries le
		LEFT JOIN lotteries l ON l.id = le.lottoId
	) t
	CROSS JOIN calc_first_month cfm
	WHERE EXISTS (SELECT 1 FROM calc_decile cd WHERE cd.member = t.member AND cd.decile = 10)
		AND t.date >= cfm.first_day
	GROUP BY week, t.member
),
calc_user_count_threshold AS (
-- Count the number of people within 50% of achieving the rewards
	SELECT
		week,
		SUM(CASE
			WHEN cudw.total_wager > iv.reward_threshold * .5 AND cudw.total_wager < iv.reward_threshold * 1 THEN 1
			ELSE 0
		END) AS f1
	FROM calc_user_daily_wager cudw
	CROSS JOIN input_variables iv
	GROUP BY week
)
SELECT * FROM calc_user_count_threshold
/*
===== Interpretation: =====
Query was left intentionally not finished after realizing even after grouping by week instead of the original day model, very few users have historically been gambling
in the millions per week, let alone consistently. Anything less than offering 25k is the equivalent of offering a 10 dollar bill to a millionaire. Sure they will take
it, but it won't change their spending habits.

===== Business Recommendation: =====
Do not do any reward program and if one is implemented in the future, the only realistic option is to increase the minimum house cut, but that would require its own analysis.
Instead of a reward program, offer a VIP role and leaderboard for users that gamble any amount every day, >100k every day, >500k every day.

===== Learning Opportunity: =====
Perform a box plot analysis before prescriptive analytics modeling a proposed reward system that is unobtainable.
 */

/* ---------- Query 8: Why the Cashback Model was Rejected ----------
===== Premise: =====
Due to a flawed approach of performing a deep dive analysis that was fundamentally flawed because descriptive analytics was not performed first, here is the data summary.

===== Business Question: =====
What is the data summary?

===== Expected Query Results: =====
Return the lower bound, q1, q2, q3, upper bound, and average of gambling wagers in the top decile of income earners.
*/
WITH calc_first_day AS (
-- Finds the first month that gambling started
	SELECT
		MIN(date) AS first_day -- Accepting the first month of gambling even though skewed because users are capable of gambling at this rate for events
	FROM death_rolls -- only 1 table because all gambling except lottery introduced at the same time
),
create_sales_table AS (
-- Combines all sales tables into 1 master table where the run was confirmed
	SELECT member, cut FROM balance_legacy WHERE confirmed = 'T'
	UNION ALL
	SELECT member, cut FROM balance_m_plus WHERE confirmed = 'T'
	UNION ALL
	SELECT member, cut FROM balance_mount WHERE confirmed = 'T'
	UNION ALL
	SELECT member, cut FROM balance_other WHERE confirmed = 'T'
	UNION ALL
	SELECT member, cut FROM balance_pvp WHERE confirmed = 'T'
	UNION ALL
	SELECT member, cut FROM balance_raid WHERE confirmed = 'T'
	UNION ALL
	SELECT member, cut FROM ad_cuts -- ad_cuts table does not have a confirmed column since sales are final
),
calc_decile AS (
-- Calculates totals from every member
	SELECT
		t.member,
		NTILE(10) OVER (ORDER BY t.member_income) AS decile -- Calculates NTILEs for lifetime income because it is nearly all disposable permanently.
	FROM (
	-- Sums cut totals for each member
		SELECT
			member,
			SUM(cut) AS member_income
		FROM create_sales_table
		GROUP BY member
	) t
), -- WHERE EXISTS SELECT 1 FROM... WHERE member = member AND decile = 10
calc_user_daily_wager AS (
-- Calculates the total wager for all games per member and per day
	SELECT
		t.member,
		t.date, -- Business Week starts on Tuesday
		SUM(ABS(t.wager)) AS total_wager
	FROM (
		-- Gambling Section: Death Rolls
		SELECT starter AS member, wager, date FROM death_rolls WHERE lockedIn = 'T'
		UNION ALL
		SELECT defender AS member, wager, date FROM death_rolls WHERE lockedIn = 'T'
		UNION ALL
		-- Gambling Section: Dice Duels
		SELECT starter AS member, wager, date FROM dice_duels WHERE lockedIn = 'T'
		UNION ALL
		SELECT defender AS member, wager, date FROM dice_duels WHERE lockedIn = 'T'
		UNION ALL
		-- Gambling Section: Over/Under
		SELECT member, wager, date FROM over_under
		UNION ALL
		-- Gambling Section: Lottery
		SELECT
			le.member,
			le.quantity * l.ticketPrice,
			le.date
		FROM lottery_entries le
		LEFT JOIN lotteries l ON l.id = le.lottoId
	) t
	CROSS JOIN calc_first_day cfd
	WHERE EXISTS (SELECT 1 FROM calc_decile cd WHERE cd.member = t.member AND cd.decile = 10)
		AND t.date >= cfd.first_day
	GROUP BY t.date, t.member
),
add_rn AS(
-- Adds a row number to each row sorted by total wager
	SELECT
	*,
		ROW_NUMBER() OVER (ORDER BY total_wager) AS rn
	FROM calc_user_daily_wager cudw
)
SELECT 'Average: ' || ROUND(AVG(total_wager)) AS summary FROM add_rn
UNION ALL
SELECT
	total_wager AS quartiles
FROM add_rn ar
CROSS JOIN (
	SELECT
		COUNT(rn) as count
	FROM add_rn
) t
WHERE rn IN (1, count/4, 2*count/4, 3*count/4, count)
/*
===== Interpretation: =====
The mean is 328k, 4x higher than the median of 85k. With a max of 29M, this shows that there is an extreme right skew due to a few whales.
A meaningful rewards program needed to target the whales of gambling or the mass population. A target of 2.5M did neither.

===== Business Recommendation: =====
Reject the proposed reward program, the proposed reward system currently attracts 1-2 users in a pool of thousands; This is not feasible reward system. Instead, focus
on the VIP role reward implemented by the engineer via automation of the business's bot.

*/

DECLARE @Today date = CAST(GETDATE() AS date);
DECLARE @usagethreshold dec = 0.8;
DECLARE @weeksofsupplythreshold int = 4;

WITH master_branch AS (
    SELECT
        m.[SKU Source],
        m.[Source System ID],
        m.[Branch Code],
        m.[SKU Number],
        m.[SKU Name],
        m.[MFG Site ID],
        m.[Animal Origin Label],
        m.[Platform],
        m.[Inventory Type],
        m.[Stocking Type Label],
        m.[Item Pool Code] AS [lead_time],
        m.[Safety Stock],
        b.[Company Code]
    FROM [Plan].EDW_Master_Branch_Table AS m WITH (NOLOCK)
    INNER JOIN [PBI].[E1_Item_Branch] AS e WITH (NOLOCK)
        ON e.[Branch Code] = m.[Branch Code]
       AND e.[SKU Number] = m.[SKU Number]
       AND e.[SKU Source] = m.[SKU Source]
    INNER JOIN [PLAN].EDW_Branch_Co_Table AS b WITH (NOLOCK)
        ON b.[SKU Source] = m.[SKU Source]
       AND b.[Branch Code] = m.[Branch Code]
    WHERE m.[Platform] IN ('BID', 'GSX', 'CSD')
      AND m.[Source System ID] = 'E1'
      AND m.[Inventory Type] = 'FG'
      AND m.[Stocking Type Label] NOT LIKE 'K%'
      AND m.[Stocking Type Label] NOT LIKE '7%'
      AND CASE
              WHEN (
                       m.[Source System ID] = 'E1'
                   AND e.[Item Status] = 'ACT'
                   AND e.[Line Type] = 'S'
                   AND e.[Stocking Type] IN ('A', 'Y')
                   )
                OR (
                       m.[Source System ID] = 'E1'
                   AND e.[Item Status] = 'ACT'
                   AND e.[Line Type] = 'S'
                   AND e.[Stocking Type] IN ('T', '1', '2', '4')
                   AND (
                           e.[Supply Branch] IN ('UT4', '', 'UXX')
                        OR e.[Supply Branch] IS NULL
                       )
                   )
              THEN 0
              ELSE 1
          END = 1
),

inv_intransit_base AS (
    SELECT
        m.[SKU Number] AS [SKU_Number],
        m.[Branch Code] AS [destination_branch],
        m.[SKU Source] AS [SKU_Source],
        i.[Intransit Quantity] AS [Intransit_Quantity]
    FROM [PLAN].SVC_Interco_Intransit_Union AS i WITH (NOLOCK)
    INNER JOIN master_branch AS m WITH (NOLOCK)
        ON m.[SKU Source] = i.[SKU Source]
       AND m.[Branch Code] = i.[Recv Branch Code]
       AND m.[SKU Number] = i.[SKU Number]
),

intransit_final AS (
    SELECT *
    FROM inv_intransit_base

    UNION ALL

    SELECT
        i.[SKU Number] AS [SKU_Number],
        i.[Branch Code] AS [destination_branch],
        i.[SKU Source] AS [SKU_Source],
        i.[In-transit Quantity] AS [Intransit_Quantity]
    FROM [PLAN].EDW_Inventory_On_Hand_Table AS i WITH (NOLOCK)
    INNER JOIN master_branch AS m WITH (NOLOCK)
        ON m.[SKU Source] = i.[SKU Source]
       AND m.[Branch Code] = i.[Branch Code]
       AND m.[SKU Number] = i.[SKU Number]
    WHERE i.[In-transit Quantity] <> 0
      AND NOT EXISTS (
            SELECT 1
            FROM inv_intransit_base AS b
            WHERE b.[SKU_Number] = i.[SKU Number]
              AND b.[destination_branch] = i.[Branch Code]
              AND b.[Intransit_Quantity] = i.[In-transit Quantity]
      )
),

intransit_keys AS (
    SELECT DISTINCT
        [SKU_Number],
        [destination_branch],
        [SKU_Source]
    FROM intransit_final
),

eo_keys AS (
    SELECT DISTINCT
        f.[SKU Number],
        f.[Branch Code],
        f.[SKU Source]
    FROM FEO_Calculated_Table_Now AS f WITH (NOLOCK)
    INNER JOIN master_branch AS m WITH (NOLOCK)
        ON m.[SKU Source] = f.[SKU Source]
       AND m.[Branch Code] = f.[Branch Code]
       AND m.[SKU Number] = f.[SKU Number]
    WHERE f.[Total Reserve Qty] > 0
),

so_base AS (
    SELECT
        s.[SKU Number],
        s.[Branch Code],
        s.[SKU Source],
        s.[Lot Number],
        s.[Inventory Location Code],
        CASE WHEN s.[Sales Order Type Code] = 'S2' THEN 0 ELSE s.[Open Order Quantity] END AS [Open Order Quantity],
        CASE WHEN s.[Sales Order Type Code] = 'S2' THEN s.[Open Order Quantity] ELSE 0 END AS [Reserve Quantity],
        f2.[Fiscal Relative Period],
        TRY_CONVERT(date, CONVERT(char(8), s.[Original Promised Delivery Date (YYYYMMDD)]), 112) AS [Promise_Date]
    FROM [PLAN].EDW_SO_Open_Table AS s WITH (NOLOCK)
    INNER JOIN master_branch AS m WITH (NOLOCK)
        ON m.[SKU Source] = s.[SKU Source]
       AND m.[Branch Code] = s.[Branch Code]
       AND m.[SKU Number] = s.[SKU Number]
    LEFT JOIN [PLAN].Fiscal_Calendar AS f2
        ON f2.[Date (YYYYMMDD)] = s.[Original Promised Delivery Date (YYYYMMDD)]
    WHERE s.[Sales Order Type Code] IN ('S1', 'S8', 'S9', 'F1', 'F4', 'F5', 'F6', 'SR', 'SF', 'SJ', 'SO', 'S2')
),

lot_order_totals AS (
    SELECT
        [SKU Number],
        [Branch Code],
        [SKU Source],
        [Inventory Location Code],
        [Lot Number],
        SUM([Open Order Quantity] + [Reserve Quantity]) AS [Lot_Open_Order_Qty]
    FROM so_base
    GROUP BY
        [SKU Number],
        [Branch Code],
        [SKU Source],
        [Inventory Location Code],
        [Lot Number]
),

usage_base AS (
    SELECT
        m.[SKU Number] AS [SKU_Number],
        m.[Branch Code] AS [Branch_Code],
        m.[Source System ID] AS [Source_System_ID],
        m.[SKU Source] AS [SKU_Source],
        m.[Company Code] AS [Company_Code],
        SUM(CASE
                WHEN f.[Fiscal Relative Week] >= -26
                 AND f.[Fiscal Relative Week] < 0
                 AND u.[Company Usage Flag] = 1
                THEN u.[Transaction Quantity] * -1
                ELSE 0
            END) AS [Trailing_6M_Company_Usage],
        SUM(CASE
                WHEN f.[Fiscal Relative Week] >= -52
                 AND f.[Fiscal Relative Week] < 0
                 AND u.[Company Usage Flag] = 1
                THEN u.[Transaction Quantity] * -1
                ELSE 0
            END) AS [Trailing_12M_Company_Usage],
        COUNT(DISTINCT CASE
                           WHEN u.[Transaction Quantity] < 0
                            AND f.[Fiscal Relative Week] < 0
                            AND f.[Fiscal Relative Week] >= -26
                            AND u.[Company Usage Flag] = 1
                           THEN u.[Transaction Date Relative Week Number]
                       END) AS [Weeks_With_Company_Transaction],
        COUNT(DISTINCT CASE
                           WHEN u.[Transaction Quantity] < 0
                            AND f.[Fiscal Relative Week] < 0
                            AND f.[Fiscal Relative Week] >= -26
                            AND u.[Company Usage Flag] = 1
                           THEN f.[Fiscal Year Period Number]
                       END) AS [Periods_With_Company_Transaction],
        SUM(CASE
                WHEN f.[Fiscal Relative Week] >= -104
                 AND f.[Fiscal Relative Week] < 0
                 AND u.[Company Usage Flag] = 1
                THEN u.[Transaction Quantity] * -1
                ELSE 0
            END) AS [Trailing_24M_Company_Usage],
        SUM(CASE
                WHEN f.[Fiscal Relative Week] >= -156
                 AND f.[Fiscal Relative Week] < 0
                 AND u.[Company Usage Flag] = 1
                THEN u.[Transaction Quantity] * -1
                ELSE 0
            END) AS [Trailing_36M_Company_Usage],
        SUM(CASE
                WHEN f.[Fiscal Relative Week] >= -260
                 AND f.[Fiscal Relative Week] < 0
                 AND u.[Company Usage Flag] = 1
                THEN u.[Transaction Quantity] * -1
                ELSE 0
            END) AS [Trailing_60M_Company_Usage],
        COALESCE(e.[Exception Years], 1) AS [Reserve_Years_Window]
    FROM [PLAN].EDW_Usage_by_Type AS u WITH (NOLOCK)
    INNER JOIN master_branch AS m
        ON m.[Branch Code] = u.[Branch Code]
       AND m.[SKU Number] = u.[SKU Number]
       AND m.[SKU Source] = u.[SKU Source]
    LEFT JOIN [PLAN].Fiscal_Calendar AS f WITH (NOLOCK)
        ON f.[Date (YYYYMMDD)] = u.[Transaction Week (YYYYMMDD)]
    LEFT JOIN (
        SELECT DISTINCT
            e.[SKU Source],
            e.[SKU Number],
            e.[Exception Type],
            et.[Exception Years],
            et.[33_67_100_Flag],
            et.[Usage_Reserve_Exclude_Flag]
        FROM [Plan].[FEO_Exception_Table] AS e WITH (NOLOCK)
        LEFT JOIN [Plan].[FEO_Exception_Type_Table] AS et WITH (NOLOCK)
            ON et.[Exception Type] = e.[Exception Type]
        LEFT JOIN [Plan].[FEO_Exception_Type_Company_Table] AS etc WITH (NOLOCK)
            ON etc.[Exception Type] = e.[Exception Type]
    ) AS e
        ON e.[SKU Number] = u.[SKU Number]
       AND e.[SKU Source] = u.[SKU Source]
    WHERE f.[Fiscal Relative Week] >= -260
      AND f.[Fiscal Relative Week] < 0
    GROUP BY
        m.[SKU Number],
        m.[Branch Code],
        m.[Source System ID],
        m.[SKU Source],
        m.[Platform],
        COALESCE(e.[Exception Years], 1),
        m.[Company Code]
),

usage_final AS (
    SELECT
        ub.*,
        CASE
            WHEN ub.[Reserve_Years_Window] = 2 THEN ub.[Trailing_24M_Company_Usage]
            WHEN ub.[Reserve_Years_Window] = 3 THEN ub.[Trailing_36M_Company_Usage]
            WHEN ub.[Reserve_Years_Window] = 5 THEN ub.[Trailing_60M_Company_Usage]
            ELSE ub.[Trailing_12M_Company_Usage]
        END AS [usage_in_reserve_window]
    FROM usage_base AS ub
    WHERE CASE
              WHEN ub.[Reserve_Years_Window] = 2 THEN ub.[Trailing_24M_Company_Usage]
              WHEN ub.[Reserve_Years_Window] = 3 THEN ub.[Trailing_36M_Company_Usage]
              WHEN ub.[Reserve_Years_Window] = 5 THEN ub.[Trailing_60M_Company_Usage]
              ELSE ub.[Trailing_12M_Company_Usage]
          END > 0
),

inv_base AS (
    SELECT
        m.[SKU Number] AS [SKU Number],
        m.[Branch Code] AS [Branch Code],
        m.[Source System ID] AS [Source System ID],
        m.[SKU Source] AS [SKU Source],
        m.[Company Code] AS [Company_Code],
        m.[lead_time],
        m.[Stocking Type Label],
        m.[Safety Stock],
        i.[On Hand Quantity] AS [On_Hand_Quantity],
        i.[Inventory Value USD PMAR Amount] AS [Inventory_Value_USD_PMAR_Amount],
        i.[Lot Status Code] AS [Lot_Status_Code],
        i.[Lot Number] AS [Lot_Number],
        i.[Inventory Location Code] AS [Inventory_Location_Code],
        d.[DNSA_Date],
        x.[Days_to_DNSA],
        CASE
            WHEN m.[Animal Origin Label] IN ('AO - Animal Origin', 'FWS - Fish & Wildlife', 'XYZ - Of Animal Origin') THEN 0
            ELSE 1
        END AS [compliance_soft_flag],
        CASE
            WHEN i.[Lot Status Code] IN ('F', 'H', 'I', 'R', 'V', 'W', 'G', 'Q', 'M') THEN 0
            ELSE 1
        END AS [lot_status_soft_flag],
        CASE WHEN ek.[SKU Number] IS NOT NULL THEN 1 ELSE 0 END AS [eo_reserve_soft_flag],
        CASE WHEN ik.[SKU_Number] IS NOT NULL THEN 0 ELSE 1 END AS [intransit_soft_flag]
    FROM [PLAN].EDW_Inventory_On_Hand_Table AS i WITH (NOLOCK)
    INNER JOIN master_branch AS m WITH (NOLOCK)
        ON m.[Branch Code] = i.[Branch Code]
       AND m.[SKU Number] = i.[SKU Number]
       AND m.[SKU Source] = i.[SKU Source]
    INNER JOIN [PBI].[E1_Item_Branch] AS e WITH (NOLOCK)
        ON e.[Branch Code] = i.[Branch Code]
       AND e.[SKU Number] = i.[SKU Number]
       AND e.[SKU Source] = i.[SKU Source]
    LEFT JOIN intransit_keys AS ik
        ON ik.[SKU_Number] = m.[SKU Number]
       AND ik.[destination_branch] = m.[Branch Code]
       AND ik.[SKU_Source] = m.[SKU Source]
    LEFT JOIN eo_keys AS ek
        ON ek.[SKU Number] = m.[SKU Number]
       AND ek.[Branch Code] = m.[Branch Code]
       AND ek.[SKU Source] = m.[SKU Source]
    CROSS APPLY (
        SELECT TRY_CONVERT(date, CONVERT(char(8), i.[DNSA Date (YYYYMMDD)]), 112) AS [DNSA_Date]
    ) AS d
    CROSS APPLY (
        SELECT DATEDIFF(DAY, d.[DNSA_Date], @Today) AS [Days_to_DNSA]
    ) AS x
    WHERE i.[On Hand Quantity] <> 0
      AND x.[Days_to_DNSA] <= -21
      AND i.[Lot Status Code] NOT IN ('E', 'X', 'S')
),

inv_available AS (
    SELECT
        i.[SKU Number] AS [SKU_Number],
        i.[Branch Code] AS [Branch_Code],
        i.[Source System ID] AS [Source_System_ID],
        i.[SKU Source] AS [SKU_Source],
        i.[Company_Code],
        i.[lead_time],
        i.[Stocking Type Label] AS [stocking_type_label],
        i.[Safety Stock] AS [safety_stock],
        i.[On_Hand_Quantity],
        i.[On_Hand_Quantity] - COALESCE(lot.[Lot_Open_Order_Qty], 0) AS [Available_Quantity],
        i.[Inventory_Value_USD_PMAR_Amount],
        i.[Lot_Status_Code],
        i.[Lot_Number],
        i.[Inventory_Location_Code],
        i.[DNSA_Date],
        i.[Days_to_DNSA],
        i.[compliance_soft_flag],
        i.[lot_status_soft_flag],
        i.[eo_reserve_soft_flag],
        i.[intransit_soft_flag],
        CASE
            WHEN i.[On_Hand_Quantity] = COALESCE(lot.[Lot_Open_Order_Qty], 0) THEN 'Allocated'
            WHEN COALESCE(lot.[Lot_Open_Order_Qty], 0) > 0 THEN 'Partially Allocated'
            ELSE 'Not Allocated'
        END AS [allocated_type],
        COALESCE(branch_so.[Open_Order_Qty_Before_DNSA], 0) AS [Total_Open_SO_Quantity],
        COALESCE(lot.[Lot_Open_Order_Qty], 0) AS [Lot_Match_SO_Quantity],
        COALESCE(branch_so.[Open_Order_Qty_Before_DNSA], 0)
            - SUM(COALESCE(lot.[Lot_Open_Order_Qty], 0)) OVER (
                PARTITION BY i.[SKU Number], i.[Branch Code], i.[SKU Source]
              ) AS [Remaining Open Order Qty]
    FROM inv_base AS i
    LEFT JOIN lot_order_totals AS lot
        ON lot.[Branch Code] = i.[Branch Code]
       AND lot.[SKU Number] = i.[SKU Number]
       AND lot.[SKU Source] = i.[SKU Source]
       AND lot.[Inventory Location Code] = i.[Inventory_Location_Code]
       AND lot.[Lot Number] = i.[Lot_Number]
    OUTER APPLY (
        SELECT
            SUM(s.[Open Order Quantity]) AS [Open_Order_Qty_Before_DNSA]
        FROM so_base AS s
        WHERE s.[SKU Number] = i.[SKU Number]
          AND s.[Branch Code] = i.[Branch Code]
          AND s.[SKU Source] = i.[SKU Source]
          AND s.[Promise_Date] <= i.[DNSA_Date]
          AND s.[Fiscal Relative Period] >= -3
    ) AS branch_so
    WHERE i.[On_Hand_Quantity] > COALESCE(lot.[Lot_Open_Order_Qty], 0)
),

cum_inv AS (
    SELECT
        ia.*,
        SUM(ia.[Available_Quantity]) OVER (
            PARTITION BY ia.[SKU_Number], ia.[Branch_Code], ia.[SKU_Source]
            ORDER BY ia.[DNSA_Date], ia.[Available_Quantity], ia.[Lot_Number], ia.[Inventory_Location_Code]
            ROWS UNBOUNDED PRECEDING
        ) AS [Cumulative_Inventory]
    FROM inv_available AS ia
),

consumption AS (
    SELECT
        c.*,
        CASE
            WHEN c.[Cumulative_Inventory] <= c.[Remaining Open Order Qty] THEN c.[Cumulative_Inventory]
            ELSE c.[Remaining Open Order Qty]
        END AS [Total_Consumed_Through_Row]
    FROM cum_inv AS c
),

inv_net AS (
    SELECT
        c.*,
        LAG(c.[Total_Consumed_Through_Row], 1, 0) OVER (
            PARTITION BY c.[SKU_Number], c.[Branch_Code], c.[SKU_Source]
            ORDER BY c.[DNSA_Date], c.[Available_Quantity], c.[Lot_Number], c.[Inventory_Location_Code]
        ) AS [Previous_Total_Consumed_Through_Row]
    FROM consumption AS c
),

inv_final AS (
    SELECT
        n.*,
        n.[Total_Consumed_Through_Row] - n.[Previous_Total_Consumed_Through_Row] AS [Qty_Consumed_By_Unallocated_SO],
        n.[Available_Quantity] - (n.[Total_Consumed_Through_Row] - n.[Previous_Total_Consumed_Through_Row]) AS [Net_Available_After_Unallocated_SO],
        SUM(n.[Available_Quantity] - (n.[Total_Consumed_Through_Row] - n.[Previous_Total_Consumed_Through_Row])) OVER (
            PARTITION BY n.[SKU_Number], n.[Branch_Code], n.[SKU_Source]
        ) AS [Total_Net_Available_After_Unallocated_SO],
        n.[Inventory_Value_USD_PMAR_Amount] / n.[On_Hand_Quantity]
            * (n.[Available_Quantity] - (n.[Total_Consumed_Through_Row] - n.[Previous_Total_Consumed_Through_Row])) AS [Impact $]
    FROM inv_net AS n
    WHERE n.[Available_Quantity] - (n.[Total_Consumed_Through_Row] - n.[Previous_Total_Consumed_Through_Row]) > 0
),

metrics AS (
    SELECT
        i.*,
        COALESCE(u.[Reserve_Years_Window], 1) AS [Reserve_Years_Window],
        COALESCE(u.[usage_in_reserve_window], 0) AS [usage_in_reserve_window],
        COALESCE(u.[Trailing_6M_Company_Usage], 0) AS [Trailing_6M_Company_Usage],
        COALESCE(u.[Trailing_12M_Company_Usage], 0) AS [Trailing_12M_Company_Usage],
        COALESCE(u.[Weeks_With_Company_Transaction], 0) AS [Weeks_With_Company_Transaction],
        COALESCE(u.[Periods_With_Company_Transaction], 0) AS [Periods_With_Company_Transaction],
        CAST(COALESCE(u.[Trailing_6M_Company_Usage], 0) / 26.0 AS float) AS [weekly_usage],
        ceiling(CAST(COALESCE(u.[Trailing_6M_Company_Usage], 0) / 26.0 AS float) * @weeksofsupplythreshold) AS [usage_protection_qty]
    FROM inv_final AS i
    LEFT JOIN usage_final AS u
        ON u.[SKU_Number] = i.[SKU_Number]
       AND u.[Branch_Code] = i.[Branch_Code]
       AND u.[SKU_Source] = i.[SKU_Source]
),

protection AS (
    SELECT
        m.*,
        CASE
            WHEN m.[Trailing_6M_Company_Usage] = 0 THEN 99
            ELSE ROUND(CAST(m.[Total_Net_Available_After_Unallocated_SO] AS float) / m.[weekly_usage], 2)
        END AS [weeks_of_supply],
        CASE
            WHEN m.[Total_Net_Available_After_Unallocated_SO] > m.[usage_in_reserve_window] * @usagethreshold THEN 1
            ELSE 0
        END AS [inv_vs_reserve_usage_window_flag],
        CASE
            WHEN m.[safety_stock] = 0 THEN 0
            WHEN m.[Total_Net_Available_After_Unallocated_SO] / m.[safety_stock] > 1 THEN 1
            ELSE 0
        END AS [avail_inv_vs_ss_flag],
        CASE
            WHEN m.[safety_stock] IS NULL OR m.[safety_stock] <= 0 THEN 'MISSING_OR_ZERO_SS'
            WHEN m.[Trailing_6M_Company_Usage] = 0 THEN 'NO_USAGE_ANCHOR'
            WHEN m.[safety_stock] > m.[usage_protection_qty] * 3 THEN 'SS_TOO_HIGH_VS_USAGE'
            ELSE 'SS_REASONABLE'
        END AS [safety_stock_quality_flag],
        CASE
            WHEN m.[safety_stock] IS NULL OR m.[safety_stock] <= 0 THEN 0
            WHEN m.[Trailing_6M_Company_Usage] = 0 THEN m.[safety_stock]
            WHEN m.[safety_stock] > m.[usage_protection_qty] * 3 THEN m.[usage_protection_qty] * 3
            ELSE m.[safety_stock]
        END AS [trusted_safety_stock]
    FROM metrics AS m
),

scored AS (
    SELECT
        p.*,
        CASE
            WHEN p.[weeks_of_supply] > @weeksofsupplythreshold THEN 1
            ELSE 0
        END AS [weeks_of_supply_soft_flag],
        CASE
            WHEN p.[usage_protection_qty] > p.[trusted_safety_stock] THEN p.[usage_protection_qty]
            ELSE p.[trusted_safety_stock]
        END AS [source_protected_quantity]
    FROM protection AS p
)

SELECT
    s.*,
    s.[weeks_of_supply_soft_flag]
    + s.[inv_vs_reserve_usage_window_flag]
    + s.[avail_inv_vs_ss_flag]
    + s.[eo_reserve_soft_flag]
    + s.[compliance_soft_flag]
    + s.[lot_status_soft_flag]
    + s.[intransit_soft_flag] AS [candidate_score],
    CASE
        WHEN s.[Total_Net_Available_After_Unallocated_SO] - s.[source_protected_quantity] > 0
        THEN s.[Total_Net_Available_After_Unallocated_SO] - s.[source_protected_quantity]
        ELSE 0
    END AS [max_available_to_move]
FROM scored AS s
WHERE 1 = 1;
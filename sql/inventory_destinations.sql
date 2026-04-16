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
        SUM(s.[Open Order Quantity]) AS [Open Order Quantity]
    FROM [PLAN].EDW_SO_Open_Table AS s WITH (NOLOCK)
    INNER JOIN master_branch AS m WITH (NOLOCK)
        ON m.[SKU Source] = s.[SKU Source]
       AND m.[Branch Code] = s.[Branch Code]
       AND m.[SKU Number] = s.[SKU Number]
    LEFT JOIN [PLAN].Fiscal_Calendar AS f2
        ON f2.[Date (YYYYMMDD)] = s.[Original Promised Delivery Date (YYYYMMDD)]
    WHERE s.[Sales Order Type Code] IN ('S1', 'S8', 'S9', 'F1', 'F4', 'F5', 'F6', 'SR', 'SF', 'SJ', 'SO')
      AND f2.[Fiscal Relative Period] >= -3
    GROUP BY
        s.[SKU Number],
        s.[Branch Code],
        s.[SKU Source]
),

usage_base AS (
    SELECT
        m.[SKU Number] AS [SKU_Number],
        m.[Branch Code] AS [Branch_Code],
        m.[Source System ID] AS [Source_System_ID],
        m.[SKU Source] AS [SKU_Source],
        m.[Company Code] AS [Company_Code],
        m.[lead_time],
        m.[Stocking Type Label],
        m.[Safety Stock],
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
        m.[Company Code],
        m.[lead_time],
        m.[Stocking Type Label],
        m.[Safety Stock]
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
        SUM(i.[On Hand Quantity]) AS [On_Hand_Quantity],
        SUM(i.[Inventory Value USD PMAR Amount]) AS [Inventory_Value_USD_PMAR_Amount]
    FROM [PLAN].EDW_Inventory_On_Hand_Table AS i WITH (NOLOCK)
    INNER JOIN master_branch AS m WITH (NOLOCK)
        ON m.[Branch Code] = i.[Branch Code]
       AND m.[SKU Number] = i.[SKU Number]
       AND m.[SKU Source] = i.[SKU Source]
    INNER JOIN [PBI].[E1_Item_Branch] AS e WITH (NOLOCK)
        ON e.[Branch Code] = i.[Branch Code]
       AND e.[SKU Number] = i.[SKU Number]
       AND e.[SKU Source] = i.[SKU Source]
    --CROSS APPLY (
    --    SELECT TRY_CONVERT(date, CONVERT(char(8), i.[DNSA Date (YYYYMMDD)]), 112) AS [DNSA_Date]
    --) AS d
    --CROSS APPLY (
    --    SELECT DATEDIFF(DAY, d.[DNSA_Date], @Today) AS [Days_to_DNSA]
    --) AS x
    WHERE i.[On Hand Quantity] <> 0
      --AND x.[Days_to_DNSA] <= -21
      AND i.[Lot Status Code] NOT IN ('E', 'X', 'S')
    GROUP BY
        m.[SKU Number],
        m.[Branch Code],
        m.[Source System ID],
        m.[SKU Source],
        m.[Company Code],
        m.[lead_time],
        m.[Stocking Type Label],
        m.[Safety Stock]
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
        i.[Inventory_Value_USD_PMAR_Amount]
    FROM inv_base AS i
),

destination_metrics AS (
    SELECT
        u.*,
        COALESCE(i.[On_Hand_Quantity], 0) AS [On_Hand_Quantity],
        COALESCE(i.[Inventory_Value_USD_PMAR_Amount], 0) AS [Inventory_Value_USD_PMAR_Amount],
        COALESCE(s.[Open Order Quantity], 0) AS [Open_Order_Quantity],
        COALESCE(i.[On_Hand_Quantity], 0) - COALESCE(s.[Open Order Quantity], 0) AS [Available_Quantity],
        CAST(COALESCE(u.[Trailing_6M_Company_Usage], 0) / 26.0 AS float) AS [weekly_usage],
        CAST(COALESCE(u.[Trailing_6M_Company_Usage], 0) / 26.0 AS float) * 12 AS [weeks_of_usage_target]--,
        --CASE WHEN ik.[SKU_Number] IS NOT NULL THEN 1 ELSE 0 END AS [destination_intransit_flag],
       -- CASE WHEN ek.[SKU Number] IS NOT NULL THEN 1 ELSE 0 END AS [destination_eo_reserve_flag]
    FROM usage_final AS u
    LEFT JOIN inv_available AS i
        ON i.[SKU_Number] = u.[SKU_Number]
       AND i.[Branch_Code] = u.[Branch_Code]
       AND i.[SKU_Source] = u.[SKU_Source]
    LEFT JOIN so_base AS s
        ON s.[Branch Code] = u.[Branch_Code]
       AND s.[SKU Number] = u.[SKU_Number]
       AND s.[SKU Source] = u.[SKU_Source]
    --LEFT JOIN intransit_keys AS ik
    --    ON ik.[SKU_Number] = u.[SKU_Number]
    --   AND ik.[destination_branch] = u.[Branch_Code]
    --   AND ik.[SKU_Source] = u.[SKU_Source]
    --LEFT JOIN eo_keys AS ek
    --    ON ek.[SKU Number] = u.[SKU_Number]
    --   AND ek.[Branch Code] = u.[Branch_Code]
    --   AND ek.[SKU Source] = u.[SKU_Source]
),

destination_protection AS (
    SELECT
        dm.*,
        CASE
            WHEN dm.[Safety Stock] IS NULL OR dm.[Safety Stock] <= 0 THEN 'MISSING_OR_ZERO_SS'
            WHEN dm.[Trailing_6M_Company_Usage] = 0 THEN 'NO_USAGE_ANCHOR'
            WHEN dm.[Safety Stock] > dm.[weeks_of_usage_target] * 3 THEN 'SS_TOO_HIGH_VS_USAGE'
            ELSE 'SS_REASONABLE'
        END AS [safety_stock_quality_flag],
        CASE
            WHEN dm.[Safety Stock] IS NULL OR dm.[Safety Stock] <= 0 THEN 0
            WHEN dm.[Trailing_6M_Company_Usage] = 0 THEN dm.[Safety Stock]
            WHEN dm.[Safety Stock] > dm.[weeks_of_usage_target] * 3 THEN dm.[weeks_of_usage_target] * 3
            ELSE dm.[Safety Stock]
        END AS [trusted_safety_stock]
    FROM destination_metrics AS dm
),

destination_targets AS (
    SELECT
        dp.*,
        CASE
            WHEN dp.[trusted_safety_stock] > dp.[weeks_of_usage_target] THEN dp.[trusted_safety_stock]
            ELSE dp.[weeks_of_usage_target]
        END AS [destination_target_qty]
    FROM destination_protection AS dp
)

SELECT
    dt.*,
    CASE
        WHEN dt.[usage_in_reserve_window] = 0 THEN NULL
        ELSE 1 - (dt.[Available_Quantity] / dt.[usage_in_reserve_window])
    END AS [percent_capacity_open],
    dt.[usage_in_reserve_window] - dt.[Available_Quantity] AS [max_capacity_to_receive],
    dt.[usage_in_reserve_window] * @usagethreshold - dt.[Available_Quantity] AS [soft_capacity_to_receive],
    floor(CASE
        WHEN dt.[destination_target_qty] - dt.[Available_Quantity] > 0
        THEN dt.[destination_target_qty] - dt.[Available_Quantity]
        ELSE 0
    END ) AS [max_available_to_receive],
    floor(CASE
        WHEN (dt.[destination_target_qty] * @usagethreshold) - dt.[Available_Quantity] > 0
        THEN (dt.[destination_target_qty] * @usagethreshold) - dt.[Available_Quantity]
        ELSE 0
    END) AS [soft_available_to_receive],
    CASE
        WHEN (dt.[destination_target_qty] * @usagethreshold) - dt.[Available_Quantity] > 0 THEN 1
        ELSE 0
    END AS [receive_capacity_soft_flag],
    CASE
        WHEN (dt.[destination_target_qty] * @usagethreshold) - dt.[Available_Quantity] > 0 THEN 1
        ELSE 0
    END AS [candidate_score]
FROM destination_targets AS dt
WHERE 1 = 1

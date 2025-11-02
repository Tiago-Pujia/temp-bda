USE Com5600G13;
GO

CREATE OR ALTER VIEW app.vw_EstadoFinanciero AS
WITH ExpensasConGastos AS (
    SELECT 
        E.nroExpensa,
        E.idConsorcio,
        E.fechaGeneracion,
        E.fechaVto1,
        E.fechaVto2,
        E.montoTotal,
        -- Sumar los gastos reales (egresos)
        ISNULL(SUM(G.importe), 0) AS totalGastos
    FROM app.Tbl_Expensa E
    LEFT JOIN app.Tbl_Gasto G ON G.nroExpensa = E.nroExpensa AND G.idConsorcio = E.idConsorcio
    GROUP BY E.nroExpensa, E.idConsorcio, E.fechaGeneracion, E.fechaVto1, E.fechaVto2, E.montoTotal
),
PagosPorExpensa AS (
    SELECT
        P.nroExpensa,
        P.idConsorcio,
        SUM(CASE WHEN P.fecha BETWEEN E.fechaGeneracion AND E.fechaVto1 THEN P.monto ELSE 0 END) AS ingresosEnTermino,
        SUM(CASE WHEN P.fecha > E.fechaVto1 THEN P.monto ELSE 0 END) AS ingresosAtrasados,
        SUM(CASE WHEN P.fecha < E.fechaGeneracion THEN P.monto ELSE 0 END) AS ingresosAdelantados,
        SUM(P.monto) AS totalIngresos
    FROM app.Tbl_Pago P
    INNER JOIN app.Tbl_Expensa E ON E.nroExpensa = P.nroExpensa AND E.idConsorcio = P.idConsorcio
    GROUP BY P.nroExpensa, P.idConsorcio
)
SELECT
    ROW_NUMBER() OVER (ORDER BY EG.idConsorcio, EG.nroExpensa) AS idEstadoFinanciero,
    C.idConsorcio,
    C.nombre AS nombreConsorcio,
    EG.nroExpensa,
    EG.fechaGeneracion,
    EG.montoTotal AS montoExpensaTotal,
    -- Saldo de la expensa anterior
    LAG(EG.montoTotal, 1, 0) OVER (PARTITION BY EG.idConsorcio ORDER BY EG.nroExpensa) AS saldoAnterior,
    -- Ingresos (pagos)
    ISNULL(PP.ingresosEnTermino, 0) AS ingresosEnTermino,
    ISNULL(PP.ingresosAtrasados, 0) AS ingresosAtrasados,
    ISNULL(PP.ingresosAdelantados, 0) AS ingresosAdelantados,
    ISNULL(PP.totalIngresos, 0) AS totalIngresos,
    -- Egresos (gastos)
    EG.totalGastos AS totalEgresos,
    -- Saldo de cierre: saldo anterior + ingresos - egresos
    LAG(EG.montoTotal, 1, 0) OVER (PARTITION BY EG.idConsorcio ORDER BY EG.nroExpensa) 
    + ISNULL(PP.totalIngresos, 0) 
    - EG.totalGastos AS saldoCierre
FROM ExpensasConGastos EG
INNER JOIN app.Tbl_Consorcio C ON C.idConsorcio = EG.idConsorcio
LEFT JOIN PagosPorExpensa PP ON PP.nroExpensa = EG.nroExpensa AND PP.idConsorcio = EG.idConsorcio;
GO
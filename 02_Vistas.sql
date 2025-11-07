/*
Archivo: 02_Vistas.sql
Propósito: Contiene vistas pensadas para reportes y resúmenes financieros.
 - `app.vw_EstadoFinanciero` resume ingresos/egresos por expensa y calcula saldo acumulado
     por consorcio (útil para reportes de cierre y control de caja).
 - `app.Vw_PersonaSegura` es una vista segura que expone datos de personas con el
     criterio de seguridad previsto (usa campos desencriptados si existen).

Notas prácticas:
 - Estas vistas son set-based y pensadas para lectura (SELECT) en reportes.
 - Si las tablas subyacentes cambian (nuevas columnas o tipos), revisá el SELECT de cada
     vista antes de recrearla.
*/

USE Com5600G13;
GO

-- Vista: resumen financiero por expensa
-- Explica brevemente: agrupa expensas con gastos y pagos, calcula delta neto y saldo
-- acumulado (saldoCierre) por consorcio. Ideal para paneles y exportes.
CREATE OR ALTER VIEW app.vw_EstadoFinanciero AS
WITH ExpensasConGastos AS (
    SELECT 
        E.nroExpensa,
        E.idConsorcio,
        E.fechaGeneracion,
        E.fechaVto1,
        E.fechaVto2,
        E.montoTotal,
        ISNULL(SUM(G.importe), 0) AS totalGastos
    FROM app.Tbl_Expensa E
    LEFT JOIN app.Tbl_Gasto G
           ON G.nroExpensa = E.nroExpensa 
          AND G.idConsorcio = E.idConsorcio
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
    INNER JOIN app.Tbl_Expensa E 
            ON E.nroExpensa = P.nroExpensa 
           AND E.idConsorcio = P.idConsorcio
    GROUP BY P.nroExpensa, P.idConsorcio
),
Movimientos AS (
    SELECT 
        EG.nroExpensa,
        EG.idConsorcio,
        EG.fechaGeneracion,
        EG.fechaVto1,
        EG.fechaVto2,
        EG.montoTotal AS montoExpensaTotal,
        ISNULL(PP.ingresosEnTermino,    0) AS ingresosEnTermino,
        ISNULL(PP.ingresosAtrasados,    0) AS ingresosAtrasados,
        ISNULL(PP.ingresosAdelantados,  0) AS ingresosAdelantados,
        ISNULL(PP.totalIngresos,        0) AS totalIngresos,
        EG.totalGastos                      AS totalEgresos,
        CAST(ISNULL(PP.totalIngresos, 0) - EG.totalGastos AS DECIMAL(18,2)) AS deltaNeto
    FROM ExpensasConGastos EG
    LEFT JOIN PagosPorExpensa PP 
           ON PP.nroExpensa = EG.nroExpensa 
          AND PP.idConsorcio = EG.idConsorcio
),
Saldos AS (
    SELECT
        ROW_NUMBER() OVER (
            ORDER BY M.idConsorcio, M.fechaGeneracion, M.nroExpensa
        ) AS idEstadoFinanciero,
        M.idConsorcio,
        M.nroExpensa,
        M.fechaGeneracion,
        M.montoExpensaTotal,
        M.ingresosEnTermino,
        M.ingresosAtrasados,
        M.ingresosAdelantados,
        M.totalIngresos,
        M.totalEgresos,
        -- saldoCierre acumulado: suma progresiva por consorcio en orden fecha+nro
        CAST(SUM(M.deltaNeto) OVER (
            PARTITION BY M.idConsorcio
            ORDER BY M.fechaGeneracion, M.nroExpensa
            ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW
        ) AS DECIMAL(18,2)) AS saldoCierre
    FROM Movimientos M
)
SELECT
    S.idEstadoFinanciero,
    C.idConsorcio,
    C.nombre AS nombreConsorcio,
    S.nroExpensa,
    S.fechaGeneracion,
    S.montoExpensaTotal,
    LAG(S.saldoCierre, 1, 0) OVER (
        PARTITION BY S.idConsorcio 
        ORDER BY S.fechaGeneracion, S.nroExpensa
    ) AS saldoAnterior,
    S.ingresosEnTermino,
    S.ingresosAtrasados,
    S.ingresosAdelantados,
    S.totalIngresos,
    S.totalEgresos,
    S.saldoCierre
FROM Saldos S
INNER JOIN app.Tbl_Consorcio C 
        ON C.idConsorcio = S.idConsorcio;
GO


-- Vista: persona segura
-- Devuelve los campos básicos de `Tbl_Persona`. Usar esta vista en reportes para
-- evitar leer columnas cifradas o expuestas directamente.
CREATE OR ALTER VIEW app.Vw_PersonaSegura
AS
SELECT
    p.idPersona,
    p.nombre,
    p.apellido,
    p.dni       AS dni,
    p.email     AS email,
    p.telefono  AS telefono
FROM app.Tbl_Persona p;
GO
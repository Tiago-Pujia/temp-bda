USE Com5600G13;
GO

CREATE OR ALTER VIEW app.vw_EstadoFinanciero AS
SELECT
    ROW_NUMBER() OVER (ORDER BY C.idConsorcio) AS idEstadoFinanciero,
    C.idConsorcio,
    LAG(E.montoTotal, 1, 0) OVER (
        PARTITION BY E.idConsorcio
        ORDER BY E.nroExpensa
    ) AS saldoAnterior,
    SUM(CASE WHEN P.fecha BETWEEN E.fechaGeneracion AND E.fechaVto1 THEN P.monto ELSE 0 END) AS ingresosEnTermino,
    SUM(CASE WHEN P.fecha > E.fechaVto1 THEN P.monto ELSE 0 END) AS ingresosAtrasados,
    SUM(CASE WHEN P.fecha < E.fechaGeneracion THEN P.monto ELSE 0 END) AS ingresosAdelantados,
    SUM(P.monto) AS egresos,
    (LAG(E.montoTotal, 1, 0) OVER (
        PARTITION BY E.idConsorcio
        ORDER BY E.nroExpensa
    ) + SUM(P.monto))
    - (SUM(CASE WHEN P.fecha BETWEEN E.fechaGeneracion AND E.fechaVto1 THEN P.monto ELSE 0 END)
     + SUM(CASE WHEN P.fecha > E.fechaVto1 THEN P.monto ELSE 0 END)
     + SUM(CASE WHEN P.fecha < E.fechaGeneracion THEN P.monto ELSE 0 END)) AS saldoCierre
FROM app.Tbl_Expensa E
INNER JOIN app.Tbl_Consorcio C
    ON E.idConsorcio = C.idConsorcio
INNER JOIN app.Tbl_EstadoCuenta EC
    ON EC.nroExpensa = E.nroExpensa
    AND EC.idConsorcio = E.idConsorcio
INNER JOIN app.Tbl_Pago P
    ON P.idEstadoCuenta = EC.idEstadoCuenta
    AND P.nroUnidadFuncional = EC.nroUnidadFuncional
    AND P.idConsorcio = EC.idConsorcio
GROUP BY
    C.idConsorcio,
    E.idConsorcio,
    E.nroExpensa,
    E.montoTotal;
GO
/*
    TODO: COMPLETAR CON DATOS DEL GRUPO
    Trabajo Práctico Integrador - Bases de Datos Aplicada (3641)
    Comisión: Com5600
    Grupo: G13
    Archivo: 51_Testing_LotePruebas_Expensas.sql
    Enunciado: Juegos de prueba para validar el lote de datos de Expensas.
*/

USE Com5600G13;
GO

/* =========================================================
   PRUEBA 1: Tipos de consorcio según bauleras/cocheras
   Requisito: 
     - 1 consorcio con baulera y cochera
     - 1 sin baulera y sin cochera
     - 1 solo baulera
     - 1 solo cochera
   Resultado esperado: ver al menos 4 filas, cada una con el flag correspondiente.
   ========================================================= */

SELECT
    C.idConsorcio,
    C.nombre,
    MAX(CASE WHEN UF.metrosBaulera > 0 THEN 1 ELSE 0 END) AS TieneBaulera,
    MAX(CASE WHEN UF.metrosCochera > 0 THEN 1 ELSE 0 END) AS TieneCochera
FROM app.Tbl_Consorcio C
JOIN app.Tbl_UnidadFuncional UF ON C.idConsorcio = UF.idConsorcio
WHERE C.nombre LIKE 'CONSORCIO_TEST_%'
GROUP BY C.idConsorcio, C.nombre
ORDER BY C.idConsorcio;

-- Esperado:
--  - CONSORCIO_TEST_1_FULL_BC  -> TieneBaulera = 1, TieneCochera = 1
--  - CONSORCIO_TEST_2_SIN_BC   -> TieneBaulera = 0, TieneCochera = 0
--  - CONSORCIO_TEST_3_SOLO_BAULERA -> TieneBaulera = 1, TieneCochera = 0
--  - CONSORCIO_TEST_4_SOLO_COCHERA -> TieneBaulera = 0, TieneCochera = 1


/* =========================================================
   PRUEBA 2: Cantidad de UF por consorcio de prueba
   Requisito: cada consorcio debe tener al menos 10 UF.
   Resultado esperado: para cada consorcio de prueba, CantUF >= 10.
   ========================================================= */

SELECT
    C.idConsorcio,
    C.nombre,
    COUNT(*) AS CantidadUF
FROM app.Tbl_Consorcio C
JOIN app.Tbl_UnidadFuncional UF ON C.idConsorcio = UF.idConsorcio
WHERE C.nombre LIKE 'CONSORCIO_TEST_%'
GROUP BY C.idConsorcio, C.nombre;

-- Esperado: las 4 filas con CantidadUF = 10.


/* =========================================================
   PRUEBA 3: Meses de expensas generados para consorcio 1
   Requisito: al menos 3 meses de expensas y uno con extraordinarias.
   Resultado esperado:
     - 3 filas (enero, febrero, marzo 2025)
   ========================================================= */

DECLARE @idConsFullBC_Test INT;
SELECT @idConsFullBC_Test = idConsorcio
FROM app.Tbl_Consorcio
WHERE nombre = 'CONSORCIO_TEST_1_FULL_BC';

SELECT
    E.nroExpensa,
    E.fechaGeneracion,
    E.fechaVto1,
    E.fechaVto2,
    E.montoTotal
FROM app.Tbl_Expensa E
WHERE E.idConsorcio = @idConsFullBC_Test
  AND YEAR(E.fechaGeneracion) = 2025
ORDER BY E.fechaGeneracion;

-- Esperado: 3 expensas (2025-01-07, 2025-02-07, 2025-03-07).

-- Para verificar que al menos una expensa tiene gastos extraordinarios:
SELECT DISTINCT
    G.nroExpensa,
    MIN(G.fechaEmision) AS PrimerGastoExtra,
    SUM(GE.cantCuotas) AS TotalCuotasDeclaradas
FROM app.Tbl_Gasto G
JOIN app.Tbl_Gasto_Extraordinario GE ON G.idGasto = GE.idGasto
WHERE G.idConsorcio = @idConsFullBC_Test
GROUP BY G.nroExpensa;

-- Esperado: al menos una fila asociada a la expensa de marzo (2025-03-07).


/* =========================================================
   PRUEBA 4: Estados de cuenta generados para consorcio 1
   Requisito: existencia de Estados de cuenta y prorrateo (ítem 7).
   Resultado esperado:
     - Para cada expensa de consorcio 1 hay 10 filas en Tbl_EstadoCuenta.
   ========================================================= */

SELECT
    EC.nroExpensa,
    COUNT(*) AS CantUFConEstado
FROM app.Tbl_EstadoCuenta EC
WHERE EC.idConsorcio = @idConsFullBC_Test
GROUP BY EC.nroExpensa
ORDER BY EC.nroExpensa;

-- Esperado: cada nroExpensa de consorcio 1 para 2025 con valor 10.


/* =========================================================
   PRUEBA 5: Casos de interés por mora
   Requisito: probar interés 0%, 2% y 5% según momento de pago.
   Resultado esperado:
     - UF PB-A: interesMora = 0
     - UF 1-A: interesMora ≈ 2% de la deuda
     - UF 3-B: interesMora ≈ 5% de la deuda
   (Los valores están cargados “a mano” en el script de datos).
   ========================================================= */
   DECLARE @ExpFeb2025_C1 INT;

   SELECT @ExpFeb2025_C1 = E.nroExpensa
FROM app.Tbl_Expensa E
WHERE E.idConsorcio = @idConsFullBC_Test
  AND E.fechaGeneracion = '2025-02-07';

SELECT
    UF.piso,
    UF.departamento,
    EC.nroExpensa,
    EC.saldoAnterior,
    EC.pagoRecibido,
    EC.deuda,
    EC.interesMora,
    EC.totalAPagar
FROM app.Tbl_EstadoCuenta EC
JOIN app.Tbl_UnidadFuncional UF
    ON EC.nroUnidadFuncional = UF.idUnidadFuncional
WHERE EC.idConsorcio = @idConsFullBC_Test
  AND EC.nroExpensa = @ExpFeb2025_C1  -- si querés, setealo manualmente con SELECT previo
ORDER BY UF.piso, UF.departamento;

-- Esperado (mirando las filas):
--  - PB-A: interesMora = 0
--  - 1-A: interesMora = 240 (aprox 2% de 12000)
--  - 3-B: interesMora = 1100 (aprox 5% de 22000)

SELECT * FROM app.Tbl_Expensa WHERE fechaGeneracion = '2025-02-07';

SELECT * FROM app.Tbl_EstadoCuenta;

/* =========================================================
   PRUEBA 6: Pagos registrados (para flujo de caja semanal)
   Requisito: existencia de pagos ordinarios en distintas fechas.
   Resultado esperado:
     - Ver al menos 3 pagos en 2025 con distintos días.
   ========================================================= */

SELECT
    P.idPago,
    P.fecha,
    P.monto,
    P.nroExpensa,
    P.idConsorcio,
    P.CBU_CVU
FROM app.Tbl_Pago P
WHERE P.idConsorcio = @idConsFullBC_Test
ORDER BY P.fecha;

-- Esperado: 3 pagos (10/02, 18/02, 01/03) con montos 52000, 40000, 30000.


/* =========================================================
   PRUEBA 7: Datos de contacto de propietarios con mayor deuda
   Con esto después podés armar el Reporte 5 (top 3 morosos).
   Resultado esperado:
     - Devuelve propietarios vinculados a consorcios de prueba con algún estado de cuenta.
   ========================================================= */

SELECT TOP 5
    P.apellido,
    P.nombre,
    P.dni,
    P.email,
    P.telefono,
    SUM(EC.deuda) AS DeudaTotal
FROM app.Tbl_Persona P
JOIN app.Tbl_UFPersona UP ON P.idPersona = UP.idPersona
JOIN app.Tbl_EstadoCuenta EC ON EC.idConsorcio = UP.idConsorcio
WHERE UP.esInquilino = 0  -- propietarios
GROUP BY P.apellido, P.nombre, P.dni, P.email, P.telefono
ORDER BY DeudaTotal DESC;

-- Esperado: algunos propietarios ordenados por deuda total (el grupo después puede ajustar el join si modela propietario/UF de otra forma).

GO

EXEC importacion.Sp_CargarPagosDesdeCsv
     @rutaArchivo = N'C:\Users\PC\Desktop\consorcios\pagos_banco_lote_pruebas.csv';

GO

CREATE OR ALTER PROCEDURE reportes.Sp_ReporteEstadoFinanciero
    @Anio        INT,
    @IdConsorcio INT     = NULL,   -- NULL = todos
    @MesDesde    TINYINT = 1,      -- 1..12
    @MesHasta    TINYINT = 12,     -- 1..12
    @LogPath     NVARCHAR(4000) = NULL,
    @Verbose     BIT = 0
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @Procedimiento SYSNAME = N'reportes.Sp_ReporteEstadoFinanciero';

    IF @MesDesde < 1 OR @MesDesde > 12
       OR @MesHasta < 1 OR @MesHasta > 12
       OR @MesDesde > @MesHasta
    BEGIN
        RAISERROR(N'Rango de meses inválido.', 16, 1);
        RETURN;
    END;

    IF @Verbose = 1
        EXEC reportes.Sp_LogReporte
             @Procedimiento, 'INFO',
             N'Inicio reporte estado financiero',
             NULL, NULL, @LogPath;

    ;WITH meses AS (
        SELECT DISTINCT
            e.idConsorcio,
            YEAR(e.fechaGeneracion)  AS Anio,
            MONTH(e.fechaGeneracion) AS Mes
        FROM app.Tbl_Expensa e
        WHERE YEAR(e.fechaGeneracion) = @Anio
          AND MONTH(e.fechaGeneracion) BETWEEN @MesDesde AND @MesHasta
          AND (@IdConsorcio IS NULL OR e.idConsorcio = @IdConsorcio)
    ),
    base AS (
        SELECT
            m.idConsorcio,
            m.Anio,
            m.Mes,
            DATEFROMPARTS(m.Anio, m.Mes, 1)                  AS FechaInicio,
            EOMONTH(DATEFROMPARTS(m.Anio, m.Mes, 1))         AS FechaFin
        FROM meses m
    ),
    ingresos AS (
        SELECT
            b.idConsorcio,
            b.Anio,
            b.Mes,
            -- pagos de expensas del MISMO mes
            SUM(CASE
                    WHEN e.fechaGeneracion >= b.FechaInicio
                     AND e.fechaGeneracion <= b.FechaFin
                    THEN p.monto ELSE 0
                END) AS IngresosEnTermino,
            -- pagos de expensas de meses ANTERIORES (saldo deudor)
            SUM(CASE
                    WHEN e.fechaGeneracion < b.FechaInicio
                    THEN p.monto ELSE 0
                END) AS IngresosAdeudadas,
            -- pagos de expensas de meses POSTERIORES (adelantadas)
            SUM(CASE
                    WHEN e.fechaGeneracion > b.FechaFin
                    THEN p.monto ELSE 0
                END) AS IngresosAdelantadas,
            -- total ingresos del mes (suma de todo)
            SUM(p.monto) AS IngresosTotal
        FROM base b
        LEFT JOIN app.Tbl_Pago p
          ON p.idConsorcio = b.idConsorcio
         AND p.fecha BETWEEN b.FechaInicio AND b.FechaFin
        LEFT JOIN app.Tbl_Expensa e
          ON e.nroExpensa   = p.nroExpensa
         AND e.idConsorcio  = p.idConsorcio
        GROUP BY
            b.idConsorcio, b.Anio, b.Mes
    ),
    egresos AS (
        SELECT
            b.idConsorcio,
            b.Anio,
            b.Mes,
            SUM(g.importe) AS EgresosMes
        FROM base b
        LEFT JOIN app.Tbl_Gasto g
          ON g.idConsorcio  = b.idConsorcio
         AND g.fechaEmision BETWEEN b.FechaInicio AND b.FechaFin
        GROUP BY
            b.idConsorcio, b.Anio, b.Mes
    ),
    combinado AS (
        SELECT
            b.idConsorcio,
            b.Anio,
            b.Mes,
            ISNULL(i.IngresosTotal,       0) AS IngresosTotal,
            ISNULL(i.IngresosEnTermino,   0) AS IngresosEnTermino,
            ISNULL(i.IngresosAdeudadas,   0) AS IngresosAdeudadas,
            ISNULL(i.IngresosAdelantadas, 0) AS IngresosAdelantadas,
            ISNULL(e.EgresosMes,          0) AS EgresosMes
        FROM base b
        LEFT JOIN ingresos i
               ON i.idConsorcio = b.idConsorcio
              AND i.Anio        = b.Anio
              AND i.Mes         = b.Mes
        LEFT JOIN egresos e
               ON e.idConsorcio = b.idConsorcio
              AND e.Anio        = b.Anio
              AND e.Mes         = b.Mes
    ),
    fin AS (
        SELECT
            c.idConsorcio,
            cs.nombre AS nombreConsorcio,
            c.Anio,
            c.Mes,
            c.IngresosTotal,
            c.IngresosEnTermino,
            c.IngresosAdeudadas,
            c.IngresosAdelantadas,
            c.EgresosMes,
            -- saldo acumulado = Σ (ingresos - egresos) hasta ese mes
            SUM(c.IngresosTotal - c.EgresosMes) OVER (
                PARTITION BY c.idConsorcio
                ORDER BY     c.Anio, c.Mes
            ) AS SaldoAcumulado
        FROM combinado c
        JOIN app.Tbl_Consorcio cs
          ON cs.idConsorcio = c.idConsorcio
    )
    SELECT
        f.idConsorcio,
        f.nombreConsorcio,
        f.Anio,
        f.Mes,
        -- saldo anterior = saldo acumulado del mes previo
        LAG(f.SaldoAcumulado, 1, 0) OVER (
            PARTITION BY f.idConsorcio
            ORDER BY     f.Anio, f.Mes
        ) AS SaldoAnterior,
        f.IngresosEnTermino,
        f.IngresosAdeudadas,
        f.IngresosAdelantadas,
        f.EgresosMes                  AS EgresosGastosMes,
        f.SaldoAcumulado              AS SaldoAlCierre
    FROM fin f
    ORDER BY
        f.idConsorcio, f.Anio, f.Mes;

    IF @Verbose = 1
        EXEC reportes.Sp_LogReporte
             @Procedimiento, 'INFO',
             N'Fin OK reporte estado financiero',
             NULL, NULL, @LogPath;
END
GO

CREATE OR ALTER PROCEDURE reportes.Sp_ReporteEstadoCuentasProrrateo
    @IdConsorcio INT     = NULL,
    @Anio        INT     = NULL,
    @Mes         TINYINT = NULL,
    @NroExpensa  INT     = NULL,
    @LogPath     NVARCHAR(4000) = NULL,
    @Verbose     BIT     = 0
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @Procedimiento SYSNAME = N'reportes.Sp_ReporteEstadoCuentasProrrateo';

    IF @Verbose = 1
        EXEC reportes.Sp_LogReporte
             @Procedimiento, 'INFO',
             N'Inicio reporte estado de cuentas',
             NULL, NULL, @LogPath;

    SELECT
        c.idConsorcio,
        c.nombre                 AS Consorcio,
        e.nroExpensa,
        e.fechaGeneracion,
        ec.nroUnidadFuncional    AS Uf,
        uf.porcentaje            AS Porcentaje,
        uf.piso                  AS Piso,
        uf.departamento          AS Depto,
        CASE WHEN ISNULL(uf.metrosCochera, 0) > 0 THEN 1 ELSE 0 END AS Cocheras,
        CASE WHEN ISNULL(uf.metrosBaulera, 0) > 0 THEN 1 ELSE 0 END AS Bauleras,
        COALESCE(
            p.apellido + ', ' + p.nombre,
            p.nombre,
            p.apellido
        )                        AS Propietario,
        ec.saldoAnterior         AS SaldoAnteriorAbonado,
        ec.pagoRecibido          AS PagosRecibidos,
        ec.deuda                 AS Deuda,
        ec.interesMora           AS InteresMora,
        ec.expensasOrdinarias    AS ExpensasOrdinarias,
        ec.expensasExtraordinarias AS ExpensasExtraordinarias,
        ec.totalAPagar           AS TotalAPagar
    FROM app.Tbl_EstadoCuenta ec
    JOIN app.Tbl_UnidadFuncional uf
      ON uf.idUnidadFuncional = ec.nroUnidadFuncional
    JOIN app.Tbl_Consorcio c
      ON c.idConsorcio = ec.idConsorcio
    JOIN app.Tbl_Expensa e
      ON e.nroExpensa  = ec.nroExpensa
     AND e.idConsorcio = ec.idConsorcio
    LEFT JOIN app.Tbl_Persona p
      ON p.CBU_CVU = uf.CBU_CVU
    WHERE (@IdConsorcio IS NULL OR c.idConsorcio = @IdConsorcio)
      AND (@NroExpensa IS NULL OR e.nroExpensa = @NroExpensa)
      AND (@Anio IS NULL OR YEAR(e.fechaGeneracion) = @Anio)
      AND (@Mes  IS NULL OR MONTH(e.fechaGeneracion) = @Mes)
    ORDER BY
        c.idConsorcio,
        e.fechaGeneracion,
        ec.nroUnidadFuncional;

    IF @Verbose = 1
        EXEC reportes.Sp_LogReporte
             @Procedimiento, 'INFO',
             N'Fin OK reporte estado de cuentas',
             NULL, NULL, @LogPath;
END
GO

DECLARE @idConsFullBC_Test INT;
DECLARE @ExpMar2025_C1 INT;

SELECT @ExpMar2025_C1 = nroExpensa
FROM app.Tbl_Expensa
WHERE idConsorcio = @idConsFullBC_Test
  AND fechaGeneracion = '2025-03-07';  -- ajustá si tu expensa de marzo tiene otra fecha

-- Archivo 1: estado financiero (1..6) del consorcio de prueba
EXEC reportes.Sp_ReporteEstadoFinanciero
     @Anio        = 2025,
     @IdConsorcio = @idConsFullBC_Test,
     @MesDesde    = 1,
     @MesHasta    = 3,
     @Verbose     = 1;

-- Archivo 2: sólo estado de cuentas y prorrateo (ítem 7) para la expensa de marzo
EXEC reportes.Sp_ReporteEstadoCuentasProrrateo
     @IdConsorcio = @idConsFullBC_Test,
     @NroExpensa  = @ExpMar2025_C1,
     @Verbose     = 1;
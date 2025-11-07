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
    UF.porcentaje,
    EC.nroExpensa,
    E.fechaVto1,
    E.fechaVto2,
    P.fecha AS fechaPago,
    EC.expensasOrdinarias + EC.expensasExtraordinarias AS baseCalculo,
    EC.pagoRecibido,
    EC.deuda,
    EC.interesMora,
    -- Verificar cálculo correcto
    CASE 
        WHEN P.fecha IS NULL THEN 'Sin pago'
        WHEN P.fecha <= E.fechaVto1 THEN '0% (En término)'
        WHEN P.fecha > E.fechaVto1 AND (E.fechaVto2 IS NULL OR P.fecha <= E.fechaVto2) 
             THEN '2% (Entre vtos)'
        WHEN E.fechaVto2 IS NOT NULL AND P.fecha > E.fechaVto2 
             THEN '5% (Después 2do vto)'
    END AS categoríaMora,
    -- Calcular mora esperada
    CASE 
        WHEN P.fecha IS NULL OR P.fecha <= E.fechaVto1 THEN 0
        WHEN P.fecha > E.fechaVto1 AND (E.fechaVto2 IS NULL OR P.fecha <= E.fechaVto2) 
             THEN ROUND(0.02 * EC.deuda, 2)
        WHEN E.fechaVto2 IS NOT NULL AND P.fecha > E.fechaVto2 
             THEN ROUND(0.05 * EC.deuda, 2)
    END AS moraEsperada,
    -- Validar
    CASE 
        WHEN EC.interesMora = CASE 
            WHEN P.fecha IS NULL OR P.fecha <= E.fechaVto1 THEN 0
            WHEN P.fecha > E.fechaVto1 AND (E.fechaVto2 IS NULL OR P.fecha <= E.fechaVto2) 
                 THEN ROUND(0.02 * EC.deuda, 2)
            WHEN E.fechaVto2 IS NOT NULL AND P.fecha > E.fechaVto2 
                 THEN ROUND(0.05 * EC.deuda, 2)
        END THEN 'OK'
        ELSE 'ERROR'
    END AS validación
FROM app.Tbl_EstadoCuenta EC
JOIN app.Tbl_UnidadFuncional UF ON EC.nroUnidadFuncional = UF.idUnidadFuncional
JOIN app.Tbl_Expensa E ON E.nroExpensa = EC.nroExpensa AND E.idConsorcio = EC.idConsorcio
LEFT JOIN (
    SELECT idEstadoCuenta, MAX(fecha) AS fecha
    FROM app.Tbl_Pago
    GROUP BY idEstadoCuenta
) P ON P.idEstadoCuenta = EC.idEstadoCuenta
WHERE EC.idConsorcio = @idConsFullBC_Test
  AND EC.nroExpensa = @ExpFeb2025_C1
ORDER BY UF.piso, UF.departamento;

-- Esperado (mirando las filas):
--  - PB-A: interesMora = 0
--  - 1-A: interesMora = 240 (aprox 2% de 12000)
--  - 3-B: interesMora = 1100 (aprox 5% de 22000)

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
    seguridad.fn_DesencriptarTexto(P.CBU_CVU_Cifrado) AS CBU_CVU
FROM app.Tbl_Pago AS P
WHERE P.idConsorcio = @idConsFullBC_Test
ORDER BY P.fecha;

-- Esperado: 3 pagos (10/02, 18/02, 01/03) con montos 52000, 40000, 30000.


/* =========================================================
   PRUEBA 7: Datos de contacto de propietarios con mayor deuda
   Con esto después podés armar el Reporte 5 (top 3 morosos).
   Resultado esperado:
     - Devuelve propietarios vinculados a consorcios de prueba con algún estado de cuenta.
   ========================================================= */

;WITH Deudas AS (
    SELECT 
        PS.idPersona,
        SUM(EC.deuda) AS DeudaTotal
    FROM app.Vw_PersonaSegura AS PS           -- trae dni/email/teléfono desencriptados
    JOIN app.Tbl_UFPersona AS UP
        ON UP.idPersona = PS.idPersona
    JOIN app.Tbl_EstadoCuenta AS EC
        ON EC.idConsorcio = UP.idConsorcio
        -- Elegí uno de estos según tu modelo:
        -- AND EC.idPersona = PS.idPersona              -- si EC referencia a la persona
        -- AND EC.idUnidadFuncional = UP.idUnidadFuncional -- si EC referencia a la UF
    WHERE UP.esInquilino = 0  -- propietarios
    GROUP BY PS.idPersona
)
SELECT TOP (5)
    PS.apellido,
    PS.nombre,
    PS.dni,
    PS.email,
    PS.telefono,
    D.DeudaTotal
FROM Deudas AS D
JOIN app.Vw_PersonaSegura AS PS
  ON PS.idPersona = D.idPersona
ORDER BY D.DeudaTotal DESC;
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
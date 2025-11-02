USE Com5600G13;
GO

/* =========================================================================
   TEST 1: REPORTE DE FLUJO DE CAJA SEMANAL
========================================================================= */
EXEC reportes.Sp_FlujoCajaSemanal
    @FechaInicio = '2025-04-01',
    @FechaFin = '2025-12-01',
    @IdConsorcio = NULL;

EXEC reportes.Sp_FlujoCajaSemanal
    @FechaInicio = '2024-11-01',
    @FechaFin = '2025-12-01',
    @IdConsorcio = 2;
/* =========================================================================
   TEST 2: RECAUDACIÓN POR MES Y DEPARTAMENTO (XML)
========================================================================= */
EXEC reportes.Sp_RecaudacionMesDepartamento
    @Anio = 2025,
    @IdConsorcio = NULL,
    @FormatoXML = 1;

/* =========================================================================
   TEST 3: RECAUDACIÓN POR PROCEDENCIA
========================================================================= */
EXEC reportes.Sp_RecaudacionPorProcedencia
    @FechaInicio = '2024-01-01',
    @FechaFin = '2025-12-31',
    @Agrupacion = 'MES';

EXEC reportes.Sp_RecaudacionPorProcedencia
    @FechaInicio = '2024-01-01',
    @FechaFin = '2025-12-31',
    @Agrupacion = 'TRIMESTRE';
/* =========================================================================
   TEST 4: TOP 5 MESES DE GASTOS E INGRESOS (CON DÓLARES)
========================================================================= */
EXEC app.Sp_ObtenerCotizacionDolar @TipoDolar = 'blue', @Verbose = 1;

EXEC reportes.Sp_Top5MesesGastosIngresos
    @Anio = NULL,  -- Todos los años
    @IdConsorcio = NULL,
    @TipoDolar = 'blue';
/* =========================================================================
   TEST 5: PROPIETARIOS MOROSOS
========================================================================= */
EXEC reportes.Sp_PropietariosMorosos
    @IdConsorcio = NULL,
    @FechaCorte = NULL,  -- Usa fecha actual
    @TopN = 3;

EXEC reportes.Sp_PropietariosMorosos
    @IdConsorcio = 1,
    @FechaCorte = '2025-12-01',
    @TopN = 5;
/* =========================================================================
   TEST 6: DÍAS ENTRE PAGOS (XML)
========================================================================= */
EXEC reportes.Sp_DiasEntrePagos
    @IdConsorcio = NULL,
    @FechaInicio = '2024-01-01',
    @FechaFin = '2025-12-31';
/* =========================================================================
   TESTS ADICIONALES: VALIDACIÓN DE DATOS
========================================================================= */
PRINT '====================================================================';
PRINT 'VALIDACIÓN DE DATOS PARA REPORTES';
PRINT '====================================================================';
PRINT '';

-- Verificar datos de pagos
PRINT 'Total de pagos registrados:';
SELECT COUNT(*) AS TotalPagos, 
       MIN(fecha) AS PrimerPago, 
       MAX(fecha) AS UltimoPago,
       SUM(monto) AS MontoTotal
FROM app.Tbl_Pago;
PRINT '';

-- Verificar gastos por tipo
PRINT 'Gastos por tipo:';
SELECT 
    tipo,
    COUNT(*) AS Cantidad,
    SUM(importe) AS ImporteTotal
FROM app.Tbl_Gasto
GROUP BY tipo;
PRINT '';

-- Verificar expensas generadas
PRINT 'Expensas por consorcio:';
SELECT 
    c.nombre AS Consorcio,
    COUNT(DISTINCT e.nroExpensa) AS TotalExpensas,
    MIN(e.fechaGeneracion) AS PrimeraExpensa,
    MAX(e.fechaGeneracion) AS UltimaExpensa
FROM app.Tbl_Expensa e
INNER JOIN app.Tbl_Consorcio c ON c.idConsorcio = e.idConsorcio
GROUP BY c.nombre;
PRINT '';

-- Verificar cotizaciones del dólar
PRINT 'Cotizaciones del dólar disponibles:';
SELECT 
    tipoDolar,
    valorCompra,
    valorVenta,
    fechaConsulta
FROM app.Tbl_CotizacionDolar
ORDER BY fechaConsulta DESC;
PRINT '';

PRINT '====================================================================';
PRINT 'TESTS COMPLETADOS EXITOSAMENTE';
PRINT '====================================================================';
GO

/* =========================================================================
   EJEMPLOS DE USO AVANZADO
========================================================================= */

-- Ejemplo: Exportar Reporte 2 a variable XML para posterior procesamiento
DECLARE @ReporteXML XML;
SET @ReporteXML = (
    SELECT 
        mes,
        departamento,
        totalRecaudado
    FROM (
        SELECT
            MONTH(e.fechaGeneracion) AS mes,
            CONCAT(ISNULL(uf.piso, 0), uf.departamento) AS departamento,
            SUM(p.monto) AS totalRecaudado
        FROM app.Tbl_Pago p
        INNER JOIN app.Tbl_Expensa e ON e.nroExpensa = p.nroExpensa
        INNER JOIN app.Tbl_UnidadFuncional uf ON uf.idUnidadFuncional = p.nroUnidadFuncional
        WHERE YEAR(e.fechaGeneracion) = 2025
        GROUP BY MONTH(e.fechaGeneracion), uf.piso, uf.departamento
    ) AS datos
    FOR XML PATH('Departamento'), ROOT('RecaudacionMensual')
);

PRINT 'XML almacenado en variable para uso posterior:';
SELECT @ReporteXML;
GO
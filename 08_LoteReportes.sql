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
EXEC api.Sp_ObtenerCotizacionDolar_Curl @TipoDolar = 'blue', @Verbose = 1;

EXEC reportes.Sp_Top5MesesGastosIngresos
    @Anio = NULL,  -- Todos los años
    @IdConsorcio = NULL,
    @TipoDolar = 'blue',
	@RefrescarCotizacion = 1;
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
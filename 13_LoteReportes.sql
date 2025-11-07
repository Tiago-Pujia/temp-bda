/*
Archivo: 13_LoteReportes.sql
Propósito: Orquestador para generar lotes de reportes automatizados. Ejecuta
procedimientos de resumen y vuelca salidas a tablas temporales para su
posterior exportación.

Consejos:
 - Revisá las rutas de exportación antes de correr en un servidor de producción.
 - Ejecutá con un usuario que tenga permisos mínimos necesarios para generar los
     reportes; evitá usar cuentas con permisos de administrador para estas tareas.
*/

USE Com5600G13;
GO

/* =========================================================================
   TEST 1: REPORTE DE FLUJO DE CAJA SEMANAL
========================================================================= */
EXEC reportes.Sp_FlujoCajaSemanal
    @FechaInicio = '2025-02-07',
    @FechaFin = '2025-12-01',
    @IdConsorcio = NULL;

EXEC reportes.Sp_FlujoCajaSemanal
    @FechaInicio = '2024-11-01',
    @FechaFin = '2025-12-01',
    @IdConsorcio = 2;
/* =========================================================================
   TEST 2: RECAUDACI�N POR MES Y DEPARTAMENTO (XML)
========================================================================= */
EXEC reportes.Sp_RecaudacionMesDepartamento
    @Anio = 2025,
    @IdConsorcio = NULL,
    @FormatoXML = 1;

/* =========================================================================
   TEST 3: RECAUDACI�N POR PROCEDENCIA
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
   TEST 4: TOP 5 MESES DE GASTOS E INGRESOS (CON D�LARES)
========================================================================= */
EXEC api.Sp_ObtenerCotizacionDolar_Curl @TipoDolar = 'blue', @Verbose = 1;

EXEC reportes.Sp_Top5MesesGastosIngresos
    @Anio = NULL,  -- Todos los a�os
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
   TEST 6: D�AS ENTRE PAGOS (XML)
========================================================================= */
EXEC reportes.Sp_DiasEntrePagos
    @IdConsorcio = NULL,
    @FechaInicio = '2024-01-01',
    @FechaFin = '2025-12-31';

EXEC app.Sp_GenerarExpensaMesSiguienteSegunPagos 
     @IdConsorcio = NULL,
     @DiaVto1 = 10,
     @DiaVto2 = 22,
     @RegistrarEnvios = 1,
     @ModoPrueba = 1;

SELECT TOP (20) * FROM app.Tbl_Expensa ORDER BY fechaGeneracion DESC;
SELECT TOP (20) * FROM app.Tbl_ExpensaEnvio ORDER BY idEnvio DESC;

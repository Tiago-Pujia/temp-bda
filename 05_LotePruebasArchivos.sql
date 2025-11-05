-- ============================================================
-- SCRIPT DE CARGA MASIVA DE DATOS PARA EL SISTEMA DE CONSORCIOS
-- Este script ejecuta todos los procedimientos de importación
-- para cargar datos iniciales desde diferentes formatos de archivo
-- ============================================================

USE Com5600G13;
GO

-- 1. Cargar consorcios desde archivo Excel (hoja 'consorcios$')
-- Importa la lista de consorcios con nombre, dirección y superficie
EXEC importacion.Sp_CargarConsorciosDesdeExcel
	@RutaArchivo = N'C:\Users\PC\Desktop\consorcios\datos varios.xlsx',
	@Hoja = N'consorcios$',
	@HDR = 1,
	@LogPath = N'C:\Users\PC\Desktop\consorcios\consorcios.log',
	@Verbose = 1;
GO

-- 2. Cargar gastos ordinarios desde archivo Excel (hoja 'Proveedores$')
-- Importa categorías de gastos y proveedores para cada consorcio
EXEC importacion.Sp_CargarGastosDesdeExcel
    @RutaArchivo       = N'C:\Users\PC\Desktop\consorcios\datos varios.xlsx',
    @Hoja              = N'Proveedores$',
    @UsarFechaExpensa  = '1900-01-01',
    @LogPath           = N'C:\Users\PC\Desktop\consorcios\gastos.log',
    @Verbose           = 1;
GO

-- 3. Cargar relación consorcio-unidades funcionales desde CSV
-- Establece la relación entre consorcios y unidades funcionales con CBU/CVU
EXEC importacion.Sp_CargarConsorcioYUF_DesdeCsv
    @RutaArchivo = N'C:\Users\PC\Desktop\consorcios\Inquilino-propietarios-UF.csv',
    @HDR         = 1,
    @LogPath     = N'C:\Users\PC\Desktop\consorcios\uf.log',
    @Verbose     = 1;
GO

-- 4. Cargar detalles de unidades funcionales desde archivo TXT
-- Importa superficie, coeficientes, bauleras y cocheras por UF
EXEC importacion.Sp_CargarUFsDesdeTxt
    @RutaArchivo    = N'C:\Users\PC\Desktop\consorcios\UF por consorcio.txt',
    @HDR            = 1,
    @RowTerminator  = N'0x0d0a',
    @CodePage       = N'65001'
    @LogPath        = N'C:\Users\PC\Desktop\consorcios\ufs_txt.log',
    @Verbose        = 1;
GO

-- 5. Cargar datos de inquilinos y propietarios desde CSV
-- Importa información personal (nombre, DNI, email, teléfono) y relación con UFs
EXEC importacion.Sp_CargarUFInquilinosDesdeCsv
    @RutaArchivo   = N'C:\Users\PC\Desktop\consorcios\Inquilino-propietarios-datos.csv',
    @HDR           = 1,
    @RowTerminator = N'0x0d0a',
    @CodePage      = N'ACP',
    @LogPath       = N'C:\Users\PC\Desktop\consorcios\uf_inq.log',
    @Verbose       = 1;
GO

-- 6. Cargar gastos mensuales desde archivo JSON
-- Importa gastos por categoría y mes para cada consorcio del año 2025
EXEC importacion.Sp_CargarGastosDesdeJson
     @RutaArchivo = N'C:\Users\PC\Desktop\consorcios\Servicios.Servicios.json',
     @Anio        = 2025,         -- Año al que corresponden los gastos
     @DiaVto1     = 10,           -- Día de vencimiento 1 para las expensas
     @DiaVto2     = 20,           -- Día de vencimiento 2 para las expensas
     @LogPath     = N'C:\Users\PC\Desktop\consorcios\gastos_json.log',
     @Verbose     = 1;
GO

-- 7. Generar estados de cuenta para todas las expensas del año 2025
-- Crea los registros de estado de cuenta para cada unidad funcional
EXEC app.Sp_GenerarEstadoCuentaDesdeExpensas
     @Anio    = 2025,
     @Verbose = 1;

-- 8. Cargar pagos realizados desde archivo CSV
-- Importa registros de pagos con fecha, CBU/CVU y monto
EXEC importacion.Sp_CargarPagosDesdeCsv
     @RutaArchivo   = N'C:\Users\PC\Desktop\consorcios\pagos_consorcios.csv',
     @HDR           = 1,
     @Separador     = ',', 
     @RowTerminator = N'0x0d0a',
     @CodePage      = N'65001',
     @LogPath       = N'C:\Users\PC\Desktop\consorcios\pagos_csv.log',
     @Verbose       = 1;
GO

-- 9. Cargar gastos extraordinarios iniciales (datos de prueba)
-- Inserta gastos extraordinarios de ejemplo para testing
EXEC app.Sp_CargarGastosExtraordinariosIniciales @Verbose = 1;
GO

-- 10. Recalcular mora e intereses para todos los estados de cuenta
-- Actualiza deudas, intereses por mora y total a pagar
EXEC app.Sp_RecalcularMoraEstadosCuenta_Todo;
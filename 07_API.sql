USE Com5600G13;
GO

/* =========================================================================
   INTEGRACIÓN API DEL DÓLAR - DolarApi.com
   Permite obtener cotizaciones actualizadas para convertir montos
========================================================================= */

-- Habilitar Ole Automation Procedures si no está habilitado
EXEC sp_configure 'show advanced options', 1;
RECONFIGURE;
GO
EXEC sp_configure 'Ole Automation Procedures', 1;
RECONFIGURE;
GO

-- Tabla para almacenar cotizaciones históricas del dólar
IF OBJECT_ID('app.Tbl_CotizacionDolar', 'U') IS NOT NULL 
    DROP TABLE app.Tbl_CotizacionDolar;
GO

CREATE TABLE app.Tbl_CotizacionDolar (
    idCotizacion INT IDENTITY(1,1) PRIMARY KEY,
    fechaConsulta DATETIME2(3) NOT NULL DEFAULT SYSUTCDATETIME(),
    tipoDolar VARCHAR(50) NOT NULL,
    valorCompra DECIMAL(10,2) NOT NULL,
    valorVenta DECIMAL(10,2) NOT NULL,
    CONSTRAINT UQ_CotizacionDolar_FechaTipo 
        UNIQUE (fechaConsulta, tipoDolar)
);
GO

CREATE INDEX IDX_Cotizacion_Fecha 
    ON app.Tbl_CotizacionDolar(fechaConsulta DESC);
GO

/* =========================================================================
   SP para obtener cotización del dólar desde la API
========================================================================= */
CREATE OR ALTER PROCEDURE app.Sp_ObtenerCotizacionDolar
    @TipoDolar VARCHAR(50) = 'blue',  -- blue, oficial, tarjeta, etc.
    @Verbose BIT = 0
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @url NVARCHAR(256) = 'https://dolarapi.com/v1/dolares/' + @TipoDolar;
    DECLARE @Object INT;
    DECLARE @respuesta NVARCHAR(MAX);
    DECLARE @hr INT;
    DECLARE @status INT;
    DECLARE @valorCompra DECIMAL(10,2);
    DECLARE @valorVenta DECIMAL(10,2);

    BEGIN TRY
        -- Crear objeto COM para HTTP
        EXEC @hr = sp_OACreate 'MSXML2.XMLHTTP', @Object OUT;
        IF @hr <> 0 
        BEGIN
            PRINT 'Error al crear objeto COM';
            RETURN -1;
        END
        
        -- Abrir conexión
        EXEC @hr = sp_OAMethod @Object, 'OPEN', NULL, 'GET', @url, 'FALSE';
        IF @hr <> 0 
        BEGIN
            PRINT 'Error al abrir conexión';
            EXEC sp_OADestroy @Object;
            RETURN -1;
        END
        
        -- Enviar solicitud
        EXEC @hr = sp_OAMethod @Object, 'SEND';
        IF @hr <> 0 
        BEGIN
            PRINT 'Error al enviar solicitud';
            EXEC sp_OADestroy @Object;
            RETURN -1;
        END
        
        -- Verificar status HTTP
        EXEC @hr = sp_OAGetProperty @Object, 'status', @status OUT;
        IF @status <> 200
        BEGIN
            PRINT 'Error HTTP: Status ' + CAST(@status AS VARCHAR(10));
            EXEC sp_OADestroy @Object;
            RETURN -1;
        END
        
        -- Obtener respuesta
        EXEC @hr = sp_OAGetProperty @Object, 'RESPONSETEXT', @respuesta OUT;
        
        IF @Verbose = 1
        BEGIN
            PRINT 'Respuesta JSON recibida:';
            PRINT @respuesta;
        END
        
        -- Extraer valores del JSON
        SET @valorCompra = CAST(JSON_VALUE(@respuesta, '$.compra') AS DECIMAL(10,2));
        SET @valorVenta = CAST(JSON_VALUE(@respuesta, '$.venta') AS DECIMAL(10,2));
        
        -- Verificar que se obtuvieron valores válidos
        IF @valorCompra IS NULL OR @valorVenta IS NULL
        BEGIN
            PRINT 'Error: No se pudieron extraer valores del JSON';
            PRINT 'JSON recibido: ' + ISNULL(@respuesta, 'NULL');
            EXEC sp_OADestroy @Object;
            RETURN -1;
        END
        
        -- Insertar en tabla
        INSERT INTO app.Tbl_CotizacionDolar (tipoDolar, valorCompra, valorVenta, fechaConsulta)
        VALUES (@TipoDolar, @valorCompra, @valorVenta, SYSUTCDATETIME());
        
        -- Liberar objeto COM
        EXEC sp_OADestroy @Object;
        
        IF @Verbose = 1
        BEGIN
            PRINT 'Cotización guardada exitosamente';
            SELECT TOP 1
                tipoDolar,
                valorCompra,
                valorVenta,
                fechaConsulta
            FROM app.Tbl_CotizacionDolar
            ORDER BY fechaConsulta DESC;
        END
        
        RETURN 0;
    END TRY
    BEGIN CATCH
        IF @Object IS NOT NULL
            EXEC sp_OADestroy @Object;
        
        PRINT 'Error al consultar API: ' + ERROR_MESSAGE();
        PRINT 'Número de error: ' + CAST(ERROR_NUMBER() AS VARCHAR(10));
        PRINT 'Línea: ' + CAST(ERROR_LINE() AS VARCHAR(10));
        RETURN -1;
    END CATCH
END
GO

/* =========================================================================
   FUNCIÓN: Obtener última cotización del dólar
========================================================================= */
CREATE OR ALTER FUNCTION app.fn_ObtenerCotizacionActual(@TipoDolar VARCHAR(50) = 'blue')
RETURNS DECIMAL(10,2)
AS
BEGIN
    DECLARE @cotizacion DECIMAL(10,2);
    
    SELECT TOP 1 @cotizacion = valorVenta
    FROM app.Tbl_CotizacionDolar
    WHERE tipoDolar = @TipoDolar
    ORDER BY fechaConsulta DESC;
    
    -- Si no hay cotización reciente (más de 1 día), retornar valor por defecto
    IF @cotizacion IS NULL OR 
       NOT EXISTS (
           SELECT 1 FROM app.Tbl_CotizacionDolar 
           WHERE tipoDolar = @TipoDolar 
           AND fechaConsulta >= DATEADD(DAY, -1, GETDATE())
       )
    BEGIN
        -- Valor por defecto actualizado (enero 2025)
        SET @cotizacion = 1250.00;
    END
    
    RETURN @cotizacion;
END
GO

/* =========================================================================
   FUNCIÓN: Convertir Pesos a Dólares
========================================================================= */
CREATE OR ALTER FUNCTION app.fn_PesosADolares(
    @Monto DECIMAL(18,2),
    @TipoDolar VARCHAR(50) = 'blue'
)
RETURNS DECIMAL(18,2)
AS
BEGIN
    DECLARE @cotizacion DECIMAL(10,2);
    
    SET @cotizacion = app.fn_ObtenerCotizacionActual(@TipoDolar);
    
    RETURN CASE 
        WHEN @cotizacion > 0 THEN @Monto / @cotizacion
        ELSE 0
    END;
END
GO

/* =========================================================================
   SP ALTERNATIVO: Cargar todas las cotizaciones principales
========================================================================= */
CREATE OR ALTER PROCEDURE app.Sp_CargarCotizacionesIniciales
    @Verbose BIT = 1
AS
BEGIN
    SET NOCOUNT ON;
    
    DECLARE @resultado INT;
    DECLARE @insertados INT = 0;
    
    PRINT 'Cargando cotizaciones del dólar...';
    PRINT '';
    
    -- Blue
    PRINT '1. Cotización Dólar Blue...';
    EXEC @resultado = app.Sp_ObtenerCotizacionDolar @TipoDolar = 'blue', @Verbose = @Verbose;
    IF @resultado = 0 SET @insertados = @insertados + 1;
    WAITFOR DELAY '00:00:01'; -- Pausa de 1 segundo entre requests
    
    -- Oficial
    PRINT '2. Cotización Dólar Oficial...';
    EXEC @resultado = app.Sp_ObtenerCotizacionDolar @TipoDolar = 'oficial', @Verbose = @Verbose;
    IF @resultado = 0 SET @insertados = @insertados + 1;
    WAITFOR DELAY '00:00:01';
    
    -- Tarjeta
    PRINT '3. Cotización Dólar Tarjeta...';
    EXEC @resultado = app.Sp_ObtenerCotizacionDolar @TipoDolar = 'tarjeta', @Verbose = @Verbose;
    IF @resultado = 0 SET @insertados = @insertados + 1;
    
    PRINT '';
    PRINT '====================================================================';
    PRINT 'Resumen: ' + CAST(@insertados AS VARCHAR(10)) + ' cotizaciones cargadas';
    PRINT '====================================================================';
    
    -- Mostrar todas las cotizaciones
    SELECT 
        tipoDolar,
        valorCompra,
        valorVenta,
        fechaConsulta,
        DATEDIFF(MINUTE, fechaConsulta, GETUTCDATE()) AS minutosDesdeConsulta
    FROM app.Tbl_CotizacionDolar
    ORDER BY fechaConsulta DESC;
END
GO

/* =========================================================================
   SP DE RESPALDO: Insertar cotizaciones manualmente si la API falla
========================================================================= */
CREATE OR ALTER PROCEDURE app.Sp_InsertarCotizacionManual
    @TipoDolar VARCHAR(50),
    @ValorCompra DECIMAL(10,2),
    @ValorVenta DECIMAL(10,2),
    @Verbose BIT = 1
AS
BEGIN
    SET NOCOUNT ON;
    
    BEGIN TRY
        INSERT INTO app.Tbl_CotizacionDolar (tipoDolar, valorCompra, valorVenta, fechaConsulta)
        VALUES (@TipoDolar, @ValorCompra, @ValorVenta, SYSUTCDATETIME());
        
        IF @Verbose = 1
        BEGIN
            PRINT 'Cotización insertada manualmente:';
            SELECT TOP 1 * FROM app.Tbl_CotizacionDolar 
            ORDER BY fechaConsulta DESC;
        END
        
        RETURN 0;
    END TRY
    BEGIN CATCH
        PRINT 'Error al insertar cotización: ' + ERROR_MESSAGE();
        RETURN -1;
    END CATCH
END
GO

/* =========================================================================
   Test inicial: cargar cotizaciones
========================================================================= */
PRINT '====================================================================';
PRINT 'PRUEBA DE INTEGRACIÓN API DEL DÓLAR';
PRINT '====================================================================';
PRINT '';

-- Intentar cargar desde la API
EXEC app.Sp_CargarCotizacionesIniciales @Verbose = 1;

PRINT '';
PRINT 'Si la API no respondió, puedes cargar valores manualmente:';
PRINT 'EXEC app.Sp_InsertarCotizacionManual ''blue'', 1200.00, 1250.00, 1;';
PRINT '';

-- Si no hay datos, insertar valores por defecto
IF NOT EXISTS (SELECT 1 FROM app.Tbl_CotizacionDolar)
BEGIN
    PRINT 'La API no respondió. Insertando valores por defecto...';
    EXEC app.Sp_InsertarCotizacionManual 'blue', 1200.00, 1250.00, 1;
    EXEC app.Sp_InsertarCotizacionManual 'oficial', 1050.00, 1100.00, 1;
    EXEC app.Sp_InsertarCotizacionManual 'tarjeta', 1800.00, 1850.00, 1;
END

-- Verificar datos cargados
PRINT '';
PRINT 'Cotizaciones disponibles en la base de datos:';
SELECT * FROM app.Tbl_CotizacionDolar ORDER BY fechaConsulta DESC;
GO
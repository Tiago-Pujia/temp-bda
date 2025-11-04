USE Com5600G13;
GO

EXEC sp_configure 'show advanced options', 1;
RECONFIGURE;
EXEC sp_configure 'xp_cmdshell', 1;
RECONFIGURE;
GO
EXEC sp_configure 'show advanced options', 1;
RECONFIGURE;
GO
EXEC sp_configure 'Ole Automation Procedures', 1;
RECONFIGURE;
GO

CREATE OR ALTER PROCEDURE api.Sp_ObtenerCotizacionDolar_Curl
    @TipoDolar VARCHAR(50) = 'blue',
    @Verbose   BIT = 0
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @Procedimiento SYSNAME = N'api.Sp_ObtenerCotizacionDolar_Curl';
    DECLARE @url NVARCHAR(256) = N'https://dolarapi.com/v1/dolares/' + @TipoDolar;
    DECLARE @cmd NVARCHAR(4000);
    DECLARE @tempFile NVARCHAR(500) = N'C:\Temp\dolar_' + @TipoDolar + N'.json';
    
    -- Crear directorio si no existe
    EXEC xp_cmdshell 'if not exist C:\Temp mkdir C:\Temp', NO_OUTPUT;

    BEGIN TRY
        -- Descargar JSON con curl
        SET @cmd = N'curl -s -o "' + @tempFile + N'" "' + @url + N'"';
        
        IF @Verbose = 1 PRINT @cmd;
        
        EXEC xp_cmdshell @cmd, NO_OUTPUT;

        -- Leer el archivo JSON
        DECLARE @json NVARCHAR(MAX);
        DECLARE @sqlRead NVARCHAR(MAX) = 
            N'SELECT @jsonOut = BulkColumn ' +
            N'FROM OPENROWSET(BULK ''' + REPLACE(@tempFile, N'''', N'''''') + N''', SINGLE_CLOB) AS j;';

        EXEC sp_executesql @sqlRead, N'@jsonOut NVARCHAR(MAX) OUTPUT', @jsonOut = @json OUTPUT;

        IF @json IS NULL OR @json = N''
        BEGIN
            EXEC reportes.Sp_LogReporte @Procedimiento, 'ERROR', N'JSON vacío o nulo', NULL, @url, NULL;
            RETURN -1;
        END

        IF @Verbose = 1 PRINT @json;

        -- Parsear valores
        DECLARE @valorCompra DECIMAL(10,2) = TRY_CAST(JSON_VALUE(@json, '$.compra') AS DECIMAL(10,2));
        DECLARE @valorVenta  DECIMAL(10,2) = TRY_CAST(JSON_VALUE(@json, '$.venta')  AS DECIMAL(10,2));

        IF @valorCompra IS NULL OR @valorVenta IS NULL
        BEGIN
            DECLARE @detErr NVARCHAR(4000) = LEFT(@json, 500);
            EXEC reportes.Sp_LogReporte @Procedimiento, 'ERROR', N'JSON sin campos esperados', @detErr, @url, NULL;
            RETURN -1;
        END

        -- Insertar en tabla
        INSERT INTO api.Tbl_CotizacionDolar(tipoDolar, valorCompra, valorVenta, fechaConsulta)
        VALUES (@TipoDolar, @valorCompra, @valorVenta, SYSUTCDATETIME());

        -- Limpiar archivo temporal
        DECLARE @cmdDel NVARCHAR(500) = N'del /Q "' + @tempFile + N'"';
        EXEC xp_cmdshell @cmdDel, NO_OUTPUT;

        IF @Verbose = 1
        BEGIN
            SELECT TOP(1) tipoDolar, valorCompra, valorVenta, fechaConsulta
            FROM api.Tbl_CotizacionDolar
            WHERE tipoDolar = @TipoDolar
            ORDER BY fechaConsulta DESC;
        END

        EXEC reportes.Sp_LogReporte @Procedimiento, 'INFO', N'Cotización obtenida OK', NULL, @url, NULL;
        RETURN 0;

    END TRY
    BEGIN CATCH
        DECLARE @msg NVARCHAR(4000) = ERROR_MESSAGE();
        DECLARE @det NVARCHAR(4000) = N'Error=' + CAST(ERROR_NUMBER() AS NVARCHAR(10));
        EXEC reportes.Sp_LogReporte @Procedimiento, 'ERROR', @msg, @det, @url, NULL;
        RETURN -1;
    END CATCH
END
GO

CREATE OR ALTER PROCEDURE api.Sp_CargarCotizacionesIniciales
    @Verbose BIT = 1,
    @Reset   BIT = 0
AS
BEGIN
    SET NOCOUNT ON;

    -- Opcional: limpiar tabla antes de cargar
    IF @Reset = 1 AND OBJECT_ID('api.Tbl_CotizacionDolar','U') IS NOT NULL
    BEGIN
        BEGIN TRY
            TRUNCATE TABLE api.Tbl_CotizacionDolar;
        END TRY
        BEGIN CATCH
            DELETE FROM api.Tbl_CotizacionDolar;
            DBCC CHECKIDENT ('api.Tbl_CotizacionDolar', RESEED, 0);
        END CATCH
    END

    DECLARE @rc INT;

    -- Intenta por XMLHTTP y, si falla, hace fallback a CURL
    EXEC @rc = api.Sp_ObtenerCotizacionDolar_Curl      @TipoDolar='blue',    @Verbose=@Verbose;
    IF @rc <> 0 EXEC @rc = api.Sp_ObtenerCotizacionDolar_Curl @TipoDolar='blue',    @Verbose=@Verbose;
    WAITFOR DELAY '00:00:01';

    EXEC @rc = api.Sp_ObtenerCotizacionDolar_Curl      @TipoDolar='oficial', @Verbose=@Verbose;
    IF @rc <> 0 EXEC @rc = api.Sp_ObtenerCotizacionDolar_Curl @TipoDolar='oficial', @Verbose=@Verbose;
    WAITFOR DELAY '00:00:01';

    EXEC @rc = api.Sp_ObtenerCotizacionDolar_Curl      @TipoDolar='tarjeta', @Verbose=@Verbose;
    IF @rc <> 0 EXEC @rc = api.Sp_ObtenerCotizacionDolar_Curl @TipoDolar='tarjeta', @Verbose=@Verbose;

    SELECT tipoDolar, valorCompra, valorVenta, fechaConsulta,
           DATEDIFF(MINUTE, fechaConsulta, SYSUTCDATETIME()) AS minutosDesdeConsulta
    FROM api.Tbl_CotizacionDolar
    ORDER BY fechaConsulta DESC;
END
GO
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

/*
Archivo: 07_API.sql
Propósito: Procedimientos para obtener y cargar cotizaciones desde APIs externas.

Resumen de objetos principales:
 - api.Sp_ObtenerCotizacionDolar_Curl(@TipoDolar, @Verbose)
         Toma un tipo de dólar (ej. 'blue', 'oficial', 'tarjeta'), descarga un JSON
         desde un endpoint público, parsea los campos 'compra' y 'venta' y guarda
         la cotización en `api.Tbl_CotizacionDolar`.

 - api.Sp_CargarCotizacionesIniciales(@Verbose, @Reset)
         Orquesta llamadas a la rutina anterior para varios tipos de dólar y muestra
         los resultados actuales.

Notas importantes y advertencias (léelas antes de ejecutar):
 - Estos procedimientos utilizan `xp_cmdshell`, `curl` y `OPENROWSET(BULK...)`.
     Su uso implica riesgos y dependencias:
         * `xp_cmdshell` debe estar habilitado y el servicio SQL corre comandos OS.
         * `curl` debe estar disponible en la máquina (o reemplazar por otro cliente).
         * `OPENROWSET(BULK...)` requiere permisos adecuados y, dependiendo de la
             configuración, `Ad Hoc Distributed Queries` habilitado.
 - Seguridad: No ejecutes estos scripts en producción sin revisar permisos OS/
     red y sin entender las implicancias de ejecutar utilidades externas.
 - Robustez: Hoy el procedimiento baja el JSON a un archivo temporal en
     `C:\Temp`. Si el servidor comparte la carpeta o el proceso falla, puede dejar
     archivos residuales. El borrado se intenta siempre, pero no es infalible.
 - JSON esperado: objeto con campos raíz `compra` y `venta`. Si la API cambia
     estructura, la rutina devolverá error y lo registrará en `reportes.Sp_LogReporte`.
*/

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
    
        /*
        Contrato / comportamiento:
        - Parámetros: @TipoDolar (string) indica la ruta específica en la API.
            @Verbose (bit) activa logging adicional por SELECT/PRINT.
        - Efecto: descarga un JSON a un archivo temporal, lo parsea y guarda
            compra/venta en `api.Tbl_CotizacionDolar`. Devuelve 0 en éxito, -1 en error.
        - Errores: se registran en `reportes.Sp_LogReporte` con contexto.
        - Consideraciones: no hay deduplicado ni upsert; cada ejecución inserta
            una nueva fila con `fechaConsulta`.
        */

        -- Crear directorio temporal si no existe (se ejecuta con permisos del servicio)
        -- Atención: xp_cmdshell corre comandos con el usuario del servicio SQL; esto
        -- tiene implicaciones de seguridad. Ver nota en el encabezado.
        EXEC xp_cmdshell 'if not exist C:\\Temp mkdir C:\\Temp', NO_OUTPUT;

    BEGIN TRY
    -- Descargar JSON con curl a un archivo temporal.
    -- Observaciones:
    --  * curl puede no estar instalado en todas las máquinas Windows.
    --  * Si necesitás usar otro cliente (powershell Invoke-WebRequest,
    --    certutil, etc.), reemplazá la línea que construye @cmd.
    SET @cmd = N'curl -s -o "' + @tempFile + N'" "' + @url + N'"';
        
    IF @Verbose = 1 PRINT @cmd;

    EXEC xp_cmdshell @cmd, NO_OUTPUT;

                /*
                Leer el contenido del archivo temporal usando OPENROWSET(BULK...).
                - OPENROWSET con SINGLE_CLOB asume texto UTF-8/ANSI según configuración.
                - Requiere permisos de acceso al archivo y que el servicio SQL pueda leer
                    la ruta indicada.
                - Si la lectura falla por permisos o por ausencia del archivo, la
                    variable @json quedará NULL y se registrará el error.
                */
                DECLARE @json NVARCHAR(MAX);
                DECLARE @sqlRead NVARCHAR(MAX) = 
                        N'SELECT @jsonOut = BulkColumn '
                        + N'FROM OPENROWSET(BULK ''' + REPLACE(@tempFile, N'''', N'''''') + N''', SINGLE_CLOB) AS j;';

                EXEC sp_executesql @sqlRead, N'@jsonOut NVARCHAR(MAX) OUTPUT', @jsonOut = @json OUTPUT;

        IF @json IS NULL OR @json = N''
        BEGIN
            EXEC reportes.Sp_LogReporte @Procedimiento, 'ERROR', N'JSON vac�o o nulo', NULL, @url, NULL;
            RETURN -1;
        END

        IF @Verbose = 1 PRINT @json;

    -- Parsear valores esperados del JSON
    -- Se espera un JSON tipo: { "compra": 123.45, "venta": 125.67 }
    -- Atención a locales / separadores: JSON_VALUE devuelve texto que se
    -- intenta castear a DECIMAL(10,2); si la API devuelve comas en vez de
    -- puntos o formato distinto, TRY_CAST devolverá NULL.
    DECLARE @valorCompra DECIMAL(10,2) = TRY_CAST(JSON_VALUE(@json, '$.compra') AS DECIMAL(10,2));
    DECLARE @valorVenta  DECIMAL(10,2) = TRY_CAST(JSON_VALUE(@json, '$.venta')  AS DECIMAL(10,2));

        IF @valorCompra IS NULL OR @valorVenta IS NULL
        BEGIN
            DECLARE @detErr NVARCHAR(4000) = LEFT(@json, 500);
            EXEC reportes.Sp_LogReporte @Procedimiento, 'ERROR', N'JSON sin campos esperados', @detErr, @url, NULL;
            RETURN -1;
        END

    -- Insertar en tabla (inserción simple, cada ejecución genera una fila)
    -- Si preferís evitar duplicados, implementá un MERGE o un criterio de
    -- deduplicado antes de insertar.
    INSERT INTO api.Tbl_CotizacionDolar(tipoDolar, valorCompra, valorVenta, fechaConsulta)
    VALUES (@TipoDolar, @valorCompra, @valorVenta, SYSUTCDATETIME());

    -- Intentar borrar el archivo temporal. Si falla, no es crítico pero
    -- puede dejar residuos en disco.
    DECLARE @cmdDel NVARCHAR(500) = N'del /Q "' + @tempFile + N'"';
    EXEC xp_cmdshell @cmdDel, NO_OUTPUT;

        IF @Verbose = 1
        BEGIN
            SELECT TOP(1) tipoDolar, valorCompra, valorVenta, fechaConsulta
            FROM api.Tbl_CotizacionDolar
            WHERE tipoDolar = @TipoDolar
            ORDER BY fechaConsulta DESC;
        END

        EXEC reportes.Sp_LogReporte @Procedimiento, 'INFO', N'Cotizaci�n obtenida OK', NULL, @url, NULL;
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

        /*
        Orquestación de cargas iniciales:
        - Ejecutamos la rutina de descarga por cada tipo de dólar deseado.
        - Nota: aquí se llama a la misma rutina dos veces en caso de error; esto
            actúa como un retry rápido. Si necesitás un fallback real a otro método
            (por ejemplo, usar XMLHTTP o PowerShell cuando curl no exista), reemplazá
            estas llamadas por la alternativa adecuada.
        - Se respeta un pequeño delay entre llamadas para evitar rate limits.
        */
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
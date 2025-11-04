USE master
GO

EXEC sys.sp_configure 'show advanced options', 1;
RECONFIGURE;
EXEC sys.sp_configure 'Ad Hoc Distributed Queries', 1;
RECONFIGURE;

EXEC dbo.sp_MSset_oledb_prop N'Microsoft.ACE.OLEDB.16.0', N'AllowInProcess', 1;
EXEC dbo.sp_MSset_oledb_prop N'Microsoft.ACE.OLEDB.16.0', N'DynamicParameters', 1;

USE Com5600G13;
GO

-- //////////////////////////////////////////////////////////////////////
CREATE OR ALTER PROCEDURE reportes.Sp_LogReporte
    @Procedimiento SYSNAME,
    @Tipo          VARCHAR(30),            -- INFO | WARN | ERROR
    @Mensaje       NVARCHAR(4000) = NULL,
    @Detalle       NVARCHAR(4000) = NULL,
    @RutaArchivo   NVARCHAR(4000) = NULL, -- archivo de datos
    @RutaLog       NVARCHAR(4000) = NULL  -- archivo .log (opcional)
AS
BEGIN
    SET NOCOUNT ON;

    -- 1) Guardar siempre en la tabla
    INSERT INTO reportes.logsReportes(procedimiento, tipo, mensaje, detalle, rutaArchivo, rutaLog)
    VALUES (@Procedimiento, @Tipo, @Mensaje, @Detalle, @RutaArchivo, @RutaLog);

    -- 2) Si pidieron archivo de log, intento escribir una línea
    IF @RutaLog IS NOT NULL
    BEGIN
        DECLARE @linea NVARCHAR(4000);
        DECLARE @cmd   NVARCHAR(4000);

        -- Armo la línea de texto (UTC yyyy-mm-dd hh:mi:ss)
        SET @linea = CONVERT(nvarchar(19), GETUTCDATE(), 120) + N' | ' +
                     ISNULL(@Procedimiento, N'') + N' | ' +
                     ISNULL(@Tipo, N'') + N' | ' +
                     ISNULL(@Mensaje, N'');

        IF @Detalle IS NOT NULL
            SET @linea = @linea + N' | ' + @Detalle;

        IF @RutaArchivo IS NOT NULL
            SET @linea = @linea + N' | src=' + @RutaArchivo;

        -- Evito comillas dobles en el echo (bien simple)
        SET @linea = REPLACE(@linea, N'"', N'''');

        SET @cmd = N'cmd /c echo "' + @linea + N'" >> "' + @RutaLog + N'"';

        BEGIN TRY
            EXEC master..xp_cmdshell @cmd, NO_OUTPUT;
        END TRY
        BEGIN CATCH
            -- Si no se pudo escribir el archivo, dejo un WARN en tabla y sigo
            INSERT INTO reportes.logsReportes(procedimiento, tipo, mensaje, detalle, rutaArchivo, rutaLog)
            VALUES (@Procedimiento, 'WARN', 'No se pudo escribir en archivo de log', ERROR_MESSAGE(), @RutaArchivo, @RutaLog);
        END CATCH
    END
END
GO
-- //////////////////////////////////////////////////////////////////////
CREATE OR ALTER PROCEDURE importacion.Sp_CargarConsorciosDesdeExcel
    @RutaArchivo NVARCHAR(4000),                 -- (xlsx/xls) OBLIGATORIO
    @Hoja        NVARCHAR(128) = N'consorcios$', -- hoja de Excel
    @HDR         BIT = 1,                        -- 1 = primera fila tiene encabezados
    @LogPath     NVARCHAR(4000) = NULL,          -- ej: 'C:\logs\consorcios.log'
    @Verbose     BIT = 0                         -- 1 = escribe logs INFO
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @Procedimiento SYSNAME = N'importacion.Sp_CargarConsorciosDesdeExcel';

    BEGIN TRY
        IF @Verbose = 1
            EXEC reportes.Sp_LogReporte @Procedimiento, 'INFO', N'Inicio de proceso', NULL, @RutaArchivo, @LogPath;

        -- 1) Normalización de parámetros
        DECLARE @HojaNormalizada NVARCHAR(128) = CASE WHEN RIGHT(@Hoja,1)=N'$' THEN @Hoja ELSE @Hoja + N'$' END;
        DECLARE @EncabezadoTexto NVARCHAR(3) = CASE WHEN @HDR = 1 THEN N'YES' ELSE N'NO' END;

        -- 2) Tabla temporal cruda (columnas iguales al Excel)
        IF OBJECT_ID('tempdb..#XlsCrudo') IS NOT NULL DROP TABLE #XlsCrudo;
        CREATE TABLE #XlsCrudo
        (
            [Nombre del consorcio] NVARCHAR(255) COLLATE DATABASE_DEFAULT NULL,
            [Domicilio]            NVARCHAR(255) COLLATE DATABASE_DEFAULT NULL,
            [m2 totales]           NVARCHAR(50)  COLLATE DATABASE_DEFAULT NULL
        );

        -- 3) OPENROWSET (SQL dinámico mínimo)
        DECLARE @Proveedor NVARCHAR(4000) =
            N'Excel 12.0 Xml;HDR=' + @EncabezadoTexto + N';IMEX=1;Database=' + REPLACE(@RutaArchivo, N'''', N'''''');
        DECLARE @Consulta  NVARCHAR(4000) =
            N'SELECT [Nombre del consorcio], [Domicilio], [m2 totales] FROM [' + @HojaNormalizada + N']';

        DECLARE @Sql NVARCHAR(MAX) = N'
INSERT INTO #XlsCrudo([Nombre del consorcio],[Domicilio],[m2 totales])
SELECT [Nombre del consorcio],[Domicilio],[m2 totales]
FROM OPENROWSET(
    ''Microsoft.ACE.OLEDB.16.0'',
    ' + QUOTENAME(@Proveedor,'''') + ',
    ' + QUOTENAME(@Consulta, '''') + '
);';

        EXEC sys.sp_executesql @Sql;

        IF @Verbose = 1
        BEGIN
            DECLARE @FilasLeidas INT = (SELECT COUNT(*) FROM #XlsCrudo);
            DECLARE @DetalleLeidas NVARCHAR(4000) = N'filas=' + CONVERT(NVARCHAR(20), @FilasLeidas);
            EXEC reportes.Sp_LogReporte @Procedimiento, 'INFO', N'Leídas filas desde Excel', @DetalleLeidas, @RutaArchivo, @LogPath;
        END

        -- 4) Staging tipado/validado (usa helpers)
        IF OBJECT_ID('tempdb..#ConsorcioStaging') IS NOT NULL DROP TABLE #ConsorcioStaging;
        CREATE TABLE #ConsorcioStaging
        (
            nombre          VARCHAR(50)     COLLATE DATABASE_DEFAULT NOT NULL,
            direccion       VARCHAR(100)    COLLATE DATABASE_DEFAULT NULL,
            superficieTotal DECIMAL(10,2)   NULL
        );

        INSERT INTO #ConsorcioStaging (nombre, direccion, superficieTotal)
        SELECT
            nombre          = importacion.fn_LimpiarTexto([Nombre del consorcio], 50),
            direccion       = importacion.fn_LimpiarTexto([Domicilio], 100),
            superficieTotal = importacion.fn_A_Decimal([m2 totales])
        FROM #XlsCrudo
        WHERE importacion.fn_LimpiarTexto([Nombre del consorcio], 50) IS NOT NULL;

        -- 5) Insert directo evitando duplicados (nombre + dirección)
        DECLARE @Insertadas INT = 0;

        INSERT INTO app.Tbl_Consorcio (nombre, direccion, superficieTotal)
        SELECT s.nombre, s.direccion, s.superficieTotal
        FROM #ConsorcioStaging s
        WHERE NOT EXISTS
        (
            SELECT 1
            FROM app.Tbl_Consorcio c
            WHERE c.nombre COLLATE DATABASE_DEFAULT = s.nombre
              AND ISNULL(c.direccion,'') COLLATE DATABASE_DEFAULT = ISNULL(s.direccion,'')
        );

        SET @Insertadas = @@ROWCOUNT;

        -- 6) Resumen + log final
        DECLARE @TotalExcel INT = (SELECT COUNT(*) FROM #XlsCrudo);
        DECLARE @Procesadas INT = (SELECT COUNT(*) FROM #ConsorcioStaging);

        IF @Verbose = 1
        BEGIN
            DECLARE @DetalleFin NVARCHAR(4000) =
                N'insertadas=' + CONVERT(NVARCHAR(20), @Insertadas) +
                N'; procesadas=' + CONVERT(NVARCHAR(20), @Procesadas) +
                N'; total_excel=' + CONVERT(NVARCHAR(20), @TotalExcel);
            EXEC reportes.Sp_LogReporte @Procedimiento, 'INFO', N'Fin OK', @DetalleFin, @RutaArchivo, @LogPath;
        END

        SELECT
            total_excel      = @TotalExcel,
            procesadas_stg   = @Procesadas,
            insertadas_final = @Insertadas,
            mensaje          = N'OK';
    END TRY
    BEGIN CATCH
        DECLARE @MensajeError  NVARCHAR(4000) = ERROR_MESSAGE();
        DECLARE @NumeroError   INT            = ERROR_NUMBER();
        DECLARE @LineaError    INT            = ERROR_LINE();

        DECLARE @DetalleError NVARCHAR(4000) =
            N'Falla en importación (' + CONVERT(NVARCHAR(20), @NumeroError) +
            N' en línea ' + CONVERT(NVARCHAR(20), @LineaError) + N')';

        EXEC reportes.Sp_LogReporte
            @Procedimiento = @Procedimiento,
            @Tipo          = 'ERROR',
            @Mensaje       = @DetalleError,
            @Detalle       = @MensajeError,
            @RutaArchivo   = @RutaArchivo,
            @RutaLog       = @LogPath;

        ;THROW;
    END CATCH
END
GO
-- //////////////////////////////////////////////////////////////////////
CREATE OR ALTER PROCEDURE importacion.Sp_CargarGastosDesdeExcel
    @RutaArchivo       NVARCHAR(4000),            -- ej: C:\...\datos varios.xlsx
    @Hoja              NVARCHAR(128) = N'Proveedores$', -- hoja de Excel
    @UsarFechaExpensa  DATE = '19000101',         -- fecha de expensa a usar/crear
    @LogPath           NVARCHAR(4000) = NULL,     -- opcional: archivo .log
    @Verbose           BIT = 0                    -- 1 = logs INFO
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @Procedimiento SYSNAME = N'importacion.Sp_CargarGastosDesdeExcel';

    BEGIN TRY
        IF @Verbose = 1
            EXEC reportes.Sp_LogReporte @Procedimiento, 'INFO', N'Inicio de proceso', NULL, @RutaArchivo, @LogPath;

        -- 1) Normalizo hoja y proveedor de Excel (HDR=NO porque leemos B3:E...)
        DECLARE @HojaOk NVARCHAR(128) = CASE WHEN RIGHT(ISNULL(@Hoja,N''),1)=N'$' THEN @Hoja ELSE @Hoja + N'$' END;

        IF OBJECT_ID('tempdb..#ExcelCrudo') IS NOT NULL DROP TABLE #ExcelCrudo;
        CREATE TABLE #ExcelCrudo
        (
            tipo_raw        NVARCHAR(255) COLLATE DATABASE_DEFAULT NULL,  -- Col B
            descripcion_raw NVARCHAR(255) COLLATE DATABASE_DEFAULT NULL,  -- Col C
            proveedor_raw   NVARCHAR(255) COLLATE DATABASE_DEFAULT NULL,  -- Col D
            consorcio_raw   NVARCHAR(255) COLLATE DATABASE_DEFAULT NULL   -- Col E (requerido)
        );

        DECLARE @Proveedor NVARCHAR(4000) =
            N'Excel 12.0;HDR=NO;IMEX=1;Database=' + REPLACE(@RutaArchivo, N'''', N'''''');
        DECLARE @Consulta NVARCHAR(4000) =
			N'SELECT * FROM [' + @HojaOk + N']';

        DECLARE @Sql NVARCHAR(MAX) = N'
INSERT INTO #ExcelCrudo(tipo_raw, descripcion_raw, proveedor_raw, consorcio_raw)
SELECT TRY_CAST(F1 AS NVARCHAR(255)),
       TRY_CAST(F2 AS NVARCHAR(255)),
       TRY_CAST(F3 AS NVARCHAR(255)),
       TRY_CAST(F4 AS NVARCHAR(255))
FROM OPENROWSET(''Microsoft.ACE.OLEDB.16.0'',
                ' + QUOTENAME(@Proveedor,'''') + ',
                ' + QUOTENAME(@Consulta, '''') + ');';

        EXEC sys.sp_executesql @Sql;

        IF @Verbose = 1
        BEGIN
            DECLARE @Leidas INT = (SELECT COUNT(*) FROM #ExcelCrudo);
            DECLARE @DetLeidas NVARCHAR(4000) = N'filas=' + CONVERT(NVARCHAR(20), @Leidas);
            EXEC reportes.Sp_LogReporte @Procedimiento, 'INFO', N'Leídas filas desde Excel', @DetLeidas, @RutaArchivo, @LogPath;
        END

        -- 2) STAGING: tipado básico y mapeo a consorcio
        IF OBJECT_ID('tempdb..#GastosStg') IS NOT NULL DROP TABLE #GastosStg;
        CREATE TABLE #GastosStg
        (
            idConsorcio INT          NOT NULL,
            categoria   VARCHAR(35)  COLLATE DATABASE_DEFAULT NULL,
            descripcion VARCHAR(200) COLLATE DATABASE_DEFAULT NULL,
            proveedor   VARCHAR(100) COLLATE DATABASE_DEFAULT NULL
        );

        INSERT INTO #GastosStg(idConsorcio, categoria, descripcion, proveedor)
        SELECT
            c.idConsorcio,
            importacion.fn_LimpiarTexto(tipo_raw,        35),
            importacion.fn_LimpiarTexto(descripcion_raw, 200),
            importacion.fn_LimpiarTexto(proveedor_raw,   100)
        FROM #ExcelCrudo r
        JOIN app.Tbl_Consorcio c
          ON c.nombre COLLATE DATABASE_DEFAULT =
             importacion.fn_LimpiarTexto(r.consorcio_raw, 50)
        WHERE importacion.fn_LimpiarTexto(r.consorcio_raw, 50) IS NOT NULL;

        -- 3) Expensas: crear las que falten para @UsarFechaExpensa
        IF OBJECT_ID('tempdb..#Expensas') IS NOT NULL DROP TABLE #Expensas;
        CREATE TABLE #Expensas (idConsorcio INT PRIMARY KEY, nroExpensa INT NOT NULL);

        -- existentes
        INSERT INTO #Expensas(idConsorcio, nroExpensa)
        SELECT e.idConsorcio, e.nroExpensa
        FROM app.Tbl_Expensa e
        JOIN (SELECT DISTINCT idConsorcio FROM #GastosStg) d ON d.idConsorcio = e.idConsorcio
        WHERE e.fechaGeneracion = @UsarFechaExpensa;

        -- crear faltantes
        INSERT INTO app.Tbl_Expensa (idConsorcio, fechaGeneracion, fechaVto1, fechaVto2, montoTotal)
        SELECT DISTINCT s.idConsorcio, @UsarFechaExpensa, NULL, NULL, 0
        FROM #GastosStg s
        WHERE NOT EXISTS (
            SELECT 1 FROM app.Tbl_Expensa e
            WHERE e.idConsorcio = s.idConsorcio AND e.fechaGeneracion = @UsarFechaExpensa
        );

        -- recargar todas a temp
        DELETE FROM #Expensas;
        INSERT INTO #Expensas(idConsorcio, nroExpensa)
        SELECT e.idConsorcio, e.nroExpensa
        FROM app.Tbl_Expensa e
        JOIN (SELECT DISTINCT idConsorcio FROM #GastosStg) d ON d.idConsorcio = e.idConsorcio
        WHERE e.fechaGeneracion = @UsarFechaExpensa;

        -- 4) Insertar Gasto evitando duplicados (por consorcio+expensa+descripcion+proveedor+categoria)
        DECLARE @GastosInsertados INT = 0;

        INSERT INTO app.Tbl_Gasto (nroExpensa, idConsorcio, tipo, descripcion, fechaEmision, importe)
        SELECT
            x.nroExpensa,
            s.idConsorcio,
            'Ordinario',
            s.descripcion,
            CAST(GETDATE() AS DATE),
            CAST(0 AS DECIMAL(10,2))
        FROM #GastosStg s
        JOIN #Expensas x ON x.idConsorcio = s.idConsorcio
        WHERE NOT EXISTS
        (
            SELECT 1
            FROM app.Tbl_Gasto g
            LEFT JOIN app.Tbl_Gasto_Ordinario go2 ON go2.idGasto = g.idGasto
            WHERE g.idConsorcio = s.idConsorcio
              AND g.nroExpensa  = x.nroExpensa
              AND ISNULL(g.descripcion,'')        COLLATE DATABASE_DEFAULT = ISNULL(s.descripcion,'')
              AND ISNULL(go2.nombreProveedor,'')  COLLATE DATABASE_DEFAULT = ISNULL(s.proveedor,'')
              AND ISNULL(go2.categoria,'')        COLLATE DATABASE_DEFAULT = ISNULL(s.categoria,'')
        );

        SET @GastosInsertados = @@ROWCOUNT;

        -- 5) Crear detalle ordinario para esos gastos (si no existe)
        INSERT INTO app.Tbl_Gasto_Ordinario (idGasto, nombreProveedor, categoria, nroFactura)
        SELECT
            g.idGasto,
            s.proveedor,
            s.categoria,
            NULL
        FROM app.Tbl_Gasto g
        JOIN #Expensas x       ON x.nroExpensa = g.nroExpensa AND x.idConsorcio = g.idConsorcio
        JOIN #GastosStg s      ON s.idConsorcio = g.idConsorcio
                              AND ISNULL(g.descripcion,'') COLLATE DATABASE_DEFAULT = ISNULL(s.descripcion,'')
        LEFT JOIN app.Tbl_Gasto_Ordinario go2 ON go2.idGasto = g.idGasto
        WHERE g.tipo = 'Ordinario'
          AND go2.idGasto IS NULL
          AND g.fechaEmision = CAST(GETDATE() AS DATE)
          AND g.importe = 0;

        -- 6) Resumen y logs
        DECLARE @TotalExcel INT = (SELECT COUNT(*) FROM #ExcelCrudo);
        DECLARE @Validas    INT = (SELECT COUNT(*) FROM #GastosStg);

        IF @Verbose = 1
        BEGIN
            DECLARE @DetFin NVARCHAR(4000) =
                N'gastos_insertados=' + CONVERT(NVARCHAR(20), @GastosInsertados) +
                N'; filas_validas=' + CONVERT(NVARCHAR(20), @Validas) +
                N'; filas_excel=' + CONVERT(NVARCHAR(20), @TotalExcel) +
                N'; fecha_expensa=' + CONVERT(NVARCHAR(10), @UsarFechaExpensa, 120);
            EXEC reportes.Sp_LogReporte @Procedimiento, 'INFO', N'Fin OK', @DetFin, @RutaArchivo, @LogPath;
        END

        SELECT
            filas_excel    = @TotalExcel,
            filas_validas  = @Validas,
            gastos_insert  = @GastosInsertados,
            mensaje        = N'OK';
    END TRY
    BEGIN CATCH
        DECLARE @MsgError NVARCHAR(4000) = ERROR_MESSAGE();
        DECLARE @NroError INT            = ERROR_NUMBER();
        DECLARE @Linea    INT            = ERROR_LINE();

        DECLARE @DetError NVARCHAR(4000) =
            N'Falla en importación (' + CONVERT(NVARCHAR(20), @NroError) +
            N' en línea ' + CONVERT(NVARCHAR(20), @Linea) + N')';

        EXEC reportes.Sp_LogReporte
            @Procedimiento = @Procedimiento,
            @Tipo          = 'ERROR',
            @Mensaje       = @DetError,
            @Detalle       = @MsgError,
            @RutaArchivo   = @RutaArchivo,
            @RutaLog       = @LogPath;

        ;THROW;
    END CATCH
END
GO
-- //////////////////////////////////////////////////////////////////////
CREATE OR ALTER PROCEDURE importacion.Sp_CargarConsorcioYUF_DesdeCsv
    @RutaArchivo NVARCHAR(4000),            -- C:\...\Inquilino-propietarios-UF.csv
    @HDR         BIT = 1,                   -- 1 = primera fila encabezado
    @LogPath     NVARCHAR(4000) = NULL,     -- opcional: archivo .log
    @Verbose     BIT = 0                    -- 1 = logs INFO
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @Procedimiento SYSNAME = N'importacion.Sp_CargarConsorcioYUF_DesdeCsv';

    BEGIN TRY
        IF @Verbose = 1
            EXEC reportes.Sp_LogReporte @Procedimiento, 'INFO', N'Inicio del proceso', NULL, @RutaArchivo, @LogPath;

        /* 1) Leer CSV (UTF-8, separador |) a tabla temporal */
        IF OBJECT_ID('tempdb..#CsvCrudo','U') IS NOT NULL DROP TABLE #CsvCrudo;
        CREATE TABLE #CsvCrudo
        (
            [CVU/CBU]              NVARCHAR(255) COLLATE DATABASE_DEFAULT NULL,
            [Nombre del consorcio] NVARCHAR(255) COLLATE DATABASE_DEFAULT NULL,
            [nroUnidadFuncional]   NVARCHAR(50)  COLLATE DATABASE_DEFAULT NULL,
            [piso]                 NVARCHAR(50)  COLLATE DATABASE_DEFAULT NULL,
            [departamento]         NVARCHAR(50)  COLLATE DATABASE_DEFAULT NULL
        );

        DECLARE @PrimeraFila INT = CASE WHEN @HDR = 1 THEN 2 ELSE 1 END;
        DECLARE @RutaEsc NVARCHAR(4000) = REPLACE(@RutaArchivo, N'''', N'''''');
        DECLARE @PrimeraFilaTxt NVARCHAR(10) = CONVERT(NVARCHAR(10), @PrimeraFila);

        DECLARE @SqlBulk NVARCHAR(MAX);
        SET @SqlBulk =
              N'BULK INSERT #CsvCrudo '
            + N'FROM ''' + @RutaEsc + N''' '
            + N'WITH ( '
            + N' FIRSTROW = ' + @PrimeraFilaTxt
            + N',FIELDTERMINATOR = ''|'''
            + N',ROWTERMINATOR   = ''0x0d0a'''
            + N',CODEPAGE        = ''65001'''
            + N',KEEPNULLS, TABLOCK );';
        EXEC (@SqlBulk);

        IF @Verbose = 1
        BEGIN
            DECLARE @FilasCsv INT = (SELECT COUNT(*) FROM #CsvCrudo);
            DECLARE @DetLeidas NVARCHAR(4000) = N'filas_csv=' + CONVERT(NVARCHAR(20), @FilasCsv);
            EXEC reportes.Sp_LogReporte @Procedimiento, 'INFO', N'Archivo leído', @DetLeidas, @RutaArchivo, @LogPath;
        END

        /* 2) STAGING (normalizo texto y CBU; PB => 0) */
        IF OBJECT_ID('tempdb..#UF_Stg','U') IS NOT NULL DROP TABLE #UF_Stg;
        CREATE TABLE #UF_Stg
        (
            idUnidadFuncional INT         NULL,  -- puede venir vacío, no lo forzamos
            nombre            VARCHAR(50) COLLATE DATABASE_DEFAULT NOT NULL,
            piso              TINYINT     NULL,
            departamento      CHAR(1)     COLLATE DATABASE_DEFAULT NULL,
            cbu_cvu_norm      CHAR(22)    COLLATE DATABASE_DEFAULT NULL
        );

        INSERT INTO #UF_Stg (idUnidadFuncional, nombre, piso, departamento, cbu_cvu_norm)
        SELECT
            TRY_CONVERT(INT, NULLIF(LTRIM(RTRIM([nroUnidadFuncional])), '')),
            importacion.fn_LimpiarTexto([Nombre del consorcio], 50),
            CASE
                WHEN UPPER(LTRIM(RTRIM([piso]))) IN (N'PB', N'P.B', N'P.B.', N'PLANTA BAJA') THEN 0
                ELSE TRY_CONVERT(TINYINT, NULLIF(LTRIM(RTRIM([piso])), ''))
            END,
            CASE
                WHEN NULLIF(LTRIM(RTRIM([departamento])), '') IS NULL THEN NULL
                ELSE SUBSTRING(LTRIM(RTRIM([departamento])), 1, 1)
            END,
            CASE
                WHEN LEN(REPLACE(REPLACE(REPLACE(REPLACE(REPLACE(REPLACE(REPLACE(REPLACE(REPLACE(REPLACE(
                         LTRIM(RTRIM([CVU/CBU])),' ',''),'-',''),'.',''),'/',''),'\',''),'_',''),
                         '(' ,''),')',''),CHAR(9),''),CHAR(160),'')) = 22
                 AND REPLACE(REPLACE(REPLACE(REPLACE(REPLACE(REPLACE(REPLACE(REPLACE(REPLACE(REPLACE(
                         LTRIM(RTRIM([CVU/CBU])),' ',''),'-',''),'.',''),'/',''),'\',''),'_',''),
                         '(' ,''),')',''),CHAR(9),''),CHAR(160),'') NOT LIKE '%[^0-9]%'
                THEN CONVERT(CHAR(22),
                     REPLACE(REPLACE(REPLACE(REPLACE(REPLACE(REPLACE(REPLACE(REPLACE(REPLACE(REPLACE(
                     LTRIM(RTRIM([CVU/CBU])),' ',''),'-',''),'.',''),'/',''),'\',''),'_',''),
                     '(' ,''),')',''),CHAR(9),''),CHAR(160),'')) 
                ELSE NULL
            END
        FROM #CsvCrudo
        WHERE importacion.fn_LimpiarTexto([Nombre del consorcio], 50) IS NOT NULL;

        /* 3) DEDUP simple */
        IF OBJECT_ID('tempdb..#UF_Dedup','U') IS NOT NULL DROP TABLE #UF_Dedup;
        SELECT DISTINCT idUnidadFuncional, nombre, piso, departamento, cbu_cvu_norm
        INTO #UF_Dedup
        FROM #UF_Stg;

        /* 4) Asegurar consorcios */
        INSERT INTO app.Tbl_Consorcio (nombre, direccion, superficieTotal)
        SELECT d.nombre, NULL, NULL
        FROM (SELECT DISTINCT nombre FROM #UF_Dedup) d
        WHERE NOT EXISTS (
            SELECT 1 FROM app.Tbl_Consorcio c 
            WHERE c.nombre COLLATE DATABASE_DEFAULT = d.nombre
        );

        /* 5) ACTUALIZAR UFs existentes
              a) por idUnidadFuncional si vino en el archivo
              b) si NO vino id, por match lógico (consorcio + piso + departamento)
              Siempre cuidando CBU_CVU UNIQUE
        */

        -- a) update por id
        UPDATE u
           SET u.piso         = d.piso,
               u.departamento = d.departamento,
               u.CBU_CVU      = CASE
                                   WHEN d.cbu_cvu_norm IS NULL THEN u.CBU_CVU
                                   WHEN u.CBU_CVU = d.cbu_cvu_norm THEN u.CBU_CVU
                                   WHEN NOT EXISTS (SELECT 1 FROM app.Tbl_UnidadFuncional x 
                                                    WHERE x.CBU_CVU = d.cbu_cvu_norm
                                                      AND x.idUnidadFuncional <> u.idUnidadFuncional)
                                   THEN d.cbu_cvu_norm
                                   ELSE u.CBU_CVU
                                END
        FROM app.Tbl_UnidadFuncional u
        JOIN #UF_Dedup d ON d.idUnidadFuncional IS NOT NULL
                        AND d.idUnidadFuncional = u.idUnidadFuncional
        JOIN app.Tbl_Consorcio c 
          ON c.nombre COLLATE DATABASE_DEFAULT = d.nombre COLLATE DATABASE_DEFAULT;

        DECLARE @upd_por_id INT = @@ROWCOUNT;

        -- b) update por (consorcio+piso+depto) cuando NO vino id
        UPDATE u
           SET u.CBU_CVU = CASE
                               WHEN d.cbu_cvu_norm IS NULL THEN u.CBU_CVU
                               WHEN u.CBU_CVU = d.cbu_cvu_norm THEN u.CBU_CVU
                               WHEN NOT EXISTS (SELECT 1 FROM app.Tbl_UnidadFuncional x 
                                                WHERE x.CBU_CVU = d.cbu_cvu_norm
                                                  AND x.idUnidadFuncional <> u.idUnidadFuncional)
                               THEN d.cbu_cvu_norm
                               ELSE u.CBU_CVU
                           END
        FROM app.Tbl_UnidadFuncional u
        JOIN app.Tbl_Consorcio c ON c.idConsorcio = u.idConsorcio
        JOIN #UF_Dedup d
          ON d.idUnidadFuncional IS NULL
         AND c.nombre COLLATE DATABASE_DEFAULT = d.nombre COLLATE DATABASE_DEFAULT
         AND ISNULL(u.piso,255) = ISNULL(d.piso,255)
         AND ISNULL(u.departamento,'') COLLATE DATABASE_DEFAULT = ISNULL(d.departamento,'') COLLATE DATABASE_DEFAULT;

        DECLARE @upd_por_match INT = @@ROWCOUNT;

        DECLARE @UFsActualizadas INT = @upd_por_id + @upd_por_match;

        /* 6) INSERTAR UFs nuevas SIN IDENTITY_INSERT
              Criterio: que NO exista ni por id (si vino) ni por match lógico
        */
        INSERT INTO app.Tbl_UnidadFuncional
            (idConsorcio, piso, departamento, superficie, metrosBaulera, metrosCochera, porcentaje, CBU_CVU)
        SELECT
            c.idConsorcio,
            d.piso,
            d.departamento,
            NULL, NULL, NULL, NULL,
            d.cbu_cvu_norm
        FROM #UF_Dedup d
        JOIN app.Tbl_Consorcio c 
          ON c.nombre COLLATE DATABASE_DEFAULT = d.nombre COLLATE DATABASE_DEFAULT
        WHERE
            -- no existe por id (cuando vino id)
            NOT EXISTS (
                SELECT 1 FROM app.Tbl_UnidadFuncional u
                WHERE d.idUnidadFuncional IS NOT NULL
                  AND u.idUnidadFuncional = d.idUnidadFuncional
            )
            -- y no existe por match lógico
            AND NOT EXISTS (
                SELECT 1 FROM app.Tbl_UnidadFuncional u
                WHERE u.idConsorcio = c.idConsorcio
                  AND ISNULL(u.piso,255) = ISNULL(d.piso,255)
                  AND ISNULL(u.departamento,'') COLLATE DATABASE_DEFAULT =
                      ISNULL(d.departamento,'') COLLATE DATABASE_DEFAULT
            )
            -- y CBU_CVU libre (si viene)
            AND (
                 d.cbu_cvu_norm IS NULL
              OR NOT EXISTS (SELECT 1 FROM app.Tbl_UnidadFuncional u2 WHERE u2.CBU_CVU = d.cbu_cvu_norm)
            );

        DECLARE @UFsInsertadas INT = @@ROWCOUNT;

        /* 7) Resumen + log */
        DECLARE @TotalCsv INT = (SELECT COUNT(*) FROM #CsvCrudo);
        DECLARE @FilasStg INT = (SELECT COUNT(*) FROM #UF_Stg);
        DECLARE @FilasDed INT = (SELECT COUNT(*) FROM #UF_Dedup);

        IF @Verbose = 1
        BEGIN
            DECLARE @DetalleFin NVARCHAR(4000);
            SET @DetalleFin = N'csv=' + CONVERT(NVARCHAR(20), @TotalCsv)
                            + N'; staging=' + CONVERT(NVARCHAR(20), @FilasStg)
                            + N'; dedup=' + CONVERT(NVARCHAR(20), @FilasDed)
                            + N'; ufs_upd=' + CONVERT(NVARCHAR(20), @UFsActualizadas)
                            + N'; ufs_ins=' + CONVERT(NVARCHAR(20), @UFsInsertadas);
            EXEC reportes.Sp_LogReporte @Procedimiento, 'INFO', N'Fin OK', @DetalleFin, @RutaArchivo, @LogPath;
        END

        SELECT
            total_csv        = @TotalCsv,
            procesadas_stg   = @FilasStg,
            sin_duplicados   = @FilasDed,
            ufs_actualizadas = @UFsActualizadas,
            ufs_insertadas   = @UFsInsertadas,
            mensaje          = N'OK';
    END TRY
    BEGIN CATCH
        DECLARE @MsgError NVARCHAR(4000) = ERROR_MESSAGE();
        DECLARE @DetErr  NVARCHAR(4000) = N'Error en línea ' + CONVERT(NVARCHAR(10), ERROR_LINE());
        EXEC reportes.Sp_LogReporte
            @Procedimiento = @Procedimiento,
            @Tipo          = 'ERROR',
            @Mensaje       = @DetErr,
            @Detalle       = @MsgError,
            @RutaArchivo   = @RutaArchivo,
            @RutaLog       = @LogPath;
        THROW;
    END CATCH
END
GO
-- //////////////////////////////////////////////////////////////////////
CREATE OR ALTER PROCEDURE importacion.Sp_CargarUFsDesdeTxt
    @RutaArchivo    NVARCHAR(4000),
    @HDR            BIT = 1,
    @RowTerminator  NVARCHAR(10) = N'0x0d0a',
    @CodePage       NVARCHAR(16) = N'65001',
    @LogPath        NVARCHAR(4000) = NULL,
    @Verbose        BIT = 0
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @Procedimiento SYSNAME = N'importacion.Sp_CargarUFsDesdeTxt';

    BEGIN TRY
        IF @Verbose = 1
            EXEC reportes.Sp_LogReporte @Procedimiento, 'INFO', N'Inicio del proceso', NULL, @RutaArchivo, @LogPath;

        /* 1) RAW */
        IF OBJECT_ID('tempdb..#RawUF','U') IS NOT NULL DROP TABLE #RawUF;
        CREATE TABLE #RawUF
        (
            [Nombre del consorcio] NVARCHAR(255) COLLATE DATABASE_DEFAULT NULL,
            [nroUnidadFuncional]   NVARCHAR(50)  COLLATE DATABASE_DEFAULT NULL,
            [Piso]                 NVARCHAR(50)  COLLATE DATABASE_DEFAULT NULL,
            [departamento]         NVARCHAR(50)  COLLATE DATABASE_DEFAULT NULL,
            [coeficiente]          NVARCHAR(50)  COLLATE DATABASE_DEFAULT NULL,
            [m2_unidad_funcional]  NVARCHAR(50)  COLLATE DATABASE_DEFAULT NULL,
            [bauleras]             NVARCHAR(10)  COLLATE DATABASE_DEFAULT NULL,
            [cochera]              NVARCHAR(10)  COLLATE DATABASE_DEFAULT NULL,
            [m2_baulera]           NVARCHAR(50)  COLLATE DATABASE_DEFAULT NULL,
            [m2_cochera]           NVARCHAR(50)  COLLATE DATABASE_DEFAULT NULL
        );

        DECLARE @PrimeraFila INT = CASE WHEN @HDR = 1 THEN 2 ELSE 1 END;
        DECLARE @RutaEsc NVARCHAR(4000) = REPLACE(@RutaArchivo, N'''', N'''''');

        DECLARE @SqlBulk NVARCHAR(MAX) =
            N'BULK INSERT #RawUF FROM ''' + @RutaEsc + N''' ' +
            N'WITH ( FIRSTROW=' + CONVERT(NVARCHAR(10), @PrimeraFila) +
            N', FIELDTERMINATOR=''0x09''' +
            N', ROWTERMINATOR=''' + @RowTerminator + N'''' +
            N', CODEPAGE='''      + @CodePage      + N'''' +
            N', KEEPNULLS, TABLOCK );';
        EXEC (@SqlBulk);

        IF @Verbose = 1
        BEGIN
            DECLARE @FilasTxt INT = (SELECT COUNT(*) FROM #RawUF);
            DECLARE @Det1 NVARCHAR(4000) = N'filas_txt=' + CONVERT(NVARCHAR(20), @FilasTxt);
            EXEC reportes.Sp_LogReporte @Procedimiento, 'INFO', N'Archivo TXT leído',
                 @Det1, @RutaArchivo, @LogPath;
        END

        /* 2) STG normalizado */
        IF OBJECT_ID('tempdb..#Stg','U') IS NOT NULL DROP TABLE #Stg;
        CREATE TABLE #Stg
        (
            nombre           VARCHAR(50)   COLLATE DATABASE_DEFAULT NOT NULL,
            piso             TINYINT       NULL,
            departamento     CHAR(1)       COLLATE DATABASE_DEFAULT NULL,
            porcentaje       DECIMAL(5,2)  NULL,
            superficie       DECIMAL(7,2)  NULL,
            metrosBaulera    DECIMAL(5,2)  NULL,
            metrosCochera    DECIMAL(5,2)  NULL
        );

        INSERT INTO #Stg (nombre, piso, departamento, porcentaje, superficie, metrosBaulera, metrosCochera)
        SELECT
            importacion.fn_LimpiarTexto([Nombre del consorcio], 50),
            CASE WHEN UPPER(LTRIM(RTRIM([Piso]))) IN (N'PB',N'P.B',N'P.B.',N'PLANTA BAJA') THEN 0
                 ELSE TRY_CONVERT(TINYINT, NULLIF(LTRIM(RTRIM([Piso])),'')) END,
            CASE WHEN NULLIF(LTRIM(RTRIM([departamento])), '') IS NULL THEN NULL
                 ELSE SUBSTRING(LTRIM(RTRIM([departamento])), 1, 1) END,
            importacion.fn_A_Decimal([coeficiente]),
            importacion.fn_A_Decimal([m2_unidad_funcional]),
            importacion.fn_A_Decimal([m2_baulera]),
            importacion.fn_A_Decimal([m2_cochera])
        FROM #RawUF
        WHERE importacion.fn_LimpiarTexto([Nombre del consorcio], 50) IS NOT NULL;

        /* 3) Consorcios */
        INSERT INTO app.Tbl_Consorcio (nombre, direccion, superficieTotal)
        SELECT DISTINCT s.nombre, NULL, NULL
        FROM #Stg s
        WHERE NOT EXISTS (
            SELECT 1 FROM app.Tbl_Consorcio c
            WHERE c.nombre COLLATE DATABASE_DEFAULT = s.nombre COLLATE DATABASE_DEFAULT
        );

        /* 4) UPDATE UFs existentes (consorcio+piso+depto) */
        UPDATE u
           SET u.superficie    = COALESCE(s.superficie, u.superficie),
               u.metrosBaulera = COALESCE(s.metrosBaulera, u.metrosBaulera),
               u.metrosCochera = COALESCE(s.metrosCochera, u.metrosCochera),
               u.porcentaje    = COALESCE(s.porcentaje, u.porcentaje)
        FROM app.Tbl_UnidadFuncional u
        JOIN app.Tbl_Consorcio c ON c.idConsorcio = u.idConsorcio
        JOIN #Stg s
          ON c.nombre COLLATE DATABASE_DEFAULT = s.nombre COLLATE DATABASE_DEFAULT
         AND ISNULL(u.piso,255) = ISNULL(s.piso,255)
         AND ISNULL(u.departamento,'') COLLATE DATABASE_DEFAULT
             = ISNULL(s.departamento,'') COLLATE DATABASE_DEFAULT;

        DECLARE @UFsActualizadas INT = @@ROWCOUNT;

        /* 5) INSERT UFs nuevas (dedup RN=1) */
        ;WITH src AS (
            SELECT
                c.idConsorcio,
                s.piso,
                s.departamento,
                s.superficie,
                s.metrosBaulera,
                s.metrosCochera,
                s.porcentaje,
                ROW_NUMBER() OVER (
                    PARTITION BY c.idConsorcio, s.piso, s.departamento
                    ORDER BY (SELECT 0)
                ) AS rn
            FROM #Stg s
            JOIN app.Tbl_Consorcio c
              ON c.nombre COLLATE DATABASE_DEFAULT = s.nombre COLLATE DATABASE_DEFAULT
        )
        INSERT INTO app.Tbl_UnidadFuncional
            (idConsorcio, piso, departamento, superficie, metrosBaulera, metrosCochera, porcentaje)
        SELECT
            x.idConsorcio, x.piso, x.departamento, x.superficie, x.metrosBaulera, x.metrosCochera, x.porcentaje
        FROM src x
        WHERE x.rn = 1
          AND NOT EXISTS (
                SELECT 1
                FROM app.Tbl_UnidadFuncional u
                WHERE u.idConsorcio = x.idConsorcio
                  AND ISNULL(u.piso,255) = ISNULL(x.piso,255)
                  AND ISNULL(u.departamento,'') COLLATE DATABASE_DEFAULT
                      = ISNULL(x.departamento,'') COLLATE DATABASE_DEFAULT
          );

        DECLARE @UFsInsertadas INT = @@ROWCOUNT;

        /* 6) Resumen + log */
        DECLARE @TotTxt INT = (SELECT COUNT(*) FROM #RawUF);
        DECLARE @TotStg INT = (SELECT COUNT(*) FROM #Stg);

        IF @Verbose = 1
        BEGIN
            DECLARE @DetFin NVARCHAR(4000) =
                N'txt=' + CONVERT(NVARCHAR(20), @TotTxt) +
                N'; stg=' + CONVERT(NVARCHAR(20), @TotStg) +
                N'; ufs_upd=' + CONVERT(NVARCHAR(20), @UFsActualizadas) +
                N'; ufs_ins=' + CONVERT(NVARCHAR(20), @UFsInsertadas);
            EXEC reportes.Sp_LogReporte @Procedimiento, 'INFO', N'Fin OK',
                 @DetFin, @RutaArchivo, @LogPath;
        END

        SELECT
            filas_txt        = @TotTxt,
            filas_validas    = @TotStg,
            ufs_actualizadas = @UFsActualizadas,
            ufs_insertadas   = @UFsInsertadas,
            mensaje          = N'OK: cargado/actualizado (PB=0; decimales normalizados; CBU_CVU NULL permitido)';
    END TRY
    BEGIN CATCH
        DECLARE @MsgError NVARCHAR(4000) = ERROR_MESSAGE();
        DECLARE @DetErr  NVARCHAR(4000) = N'Error en línea ' + CONVERT(NVARCHAR(10), ERROR_LINE());
        EXEC reportes.Sp_LogReporte
            @Procedimiento = @Procedimiento,
            @Tipo          = 'ERROR',
            @Mensaje       = @DetErr,
            @Detalle       = @MsgError,
            @RutaArchivo   = @RutaArchivo,
            @RutaLog       = @LogPath;
        THROW;
    END CATCH
END
GO
-- //////////////////////////////////////////////////////////////////////
CREATE OR ALTER PROCEDURE importacion.Sp_CargarUFInquilinosDesdeCsv
    @RutaArchivo    NVARCHAR(4000),            -- C:\...\Inquilino-propietarios-datos.csv
    @HDR            BIT = 1,                   -- 1 = primera fila encabezado
    @RowTerminator  NVARCHAR(10) = N'0x0d0a',  -- CRLF (usar '0x0a' si solo LF)
    @CodePage       NVARCHAR(16) = N'ACP',     -- Latin-1; usar '65001' si UTF-8
    @LogPath        NVARCHAR(4000) = NULL,     -- opcional: archivo .log
    @Verbose        BIT = 0                    -- 1 = logs INFO
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @Procedimiento SYSNAME = N'importacion.Sp_CargarUFInquilinosDesdeCsv';

    BEGIN TRY
        IF @Verbose = 1
        BEGIN
            DECLARE @Det0 NVARCHAR(4000) = NULL;
            EXEC reportes.Sp_LogReporte
                 @Procedimiento = @Procedimiento,
                 @Tipo          = 'INFO',
                 @Mensaje       = N'Inicio del proceso',
                 @Detalle       = @Det0,
                 @RutaArchivo   = @RutaArchivo,
                 @RutaLog       = @LogPath;
        END

        /* 1) RAW del CSV (';') */
        IF OBJECT_ID('tempdb..#Raw','U') IS NOT NULL DROP TABLE #Raw;
        CREATE TABLE #Raw
        (
            [Nombre]                 NVARCHAR(255) COLLATE DATABASE_DEFAULT NULL,
            [apellido]               NVARCHAR(255) COLLATE DATABASE_DEFAULT NULL,
            [DNI]                    NVARCHAR(50)  COLLATE DATABASE_DEFAULT NULL,
            [email personal]         NVARCHAR(255) COLLATE DATABASE_DEFAULT NULL,
            [telfono de contacto]   NVARCHAR(255) COLLATE DATABASE_DEFAULT NULL, -- viene así
            [CVU/CBU]                NVARCHAR(64)  COLLATE DATABASE_DEFAULT NULL,
            [Inquilino]              NVARCHAR(50)  COLLATE DATABASE_DEFAULT NULL
        );

        DECLARE @PrimeraFila INT = CASE WHEN @HDR=1 THEN 2 ELSE 1 END;
        DECLARE @PrimeraFilaTxt NVARCHAR(10) = CONVERT(NVARCHAR(10), @PrimeraFila);
        DECLARE @RutaEsc NVARCHAR(4000) = REPLACE(@RutaArchivo, N'''', N'''''');

        DECLARE @SqlBulk NVARCHAR(MAX);
        SET @SqlBulk = CONCAT(
            N'BULK INSERT #Raw FROM ''', @RutaEsc, N''' WITH ( ',
            N'FIRSTROW = ', @PrimeraFilaTxt,
            N', FIELDTERMINATOR = '';''',
            N', ROWTERMINATOR  = ''', @RowTerminator, N'''',
            N', CODEPAGE       = ''', @CodePage, N'''',
            N', KEEPNULLS, TABLOCK );'
        );

        EXEC (@SqlBulk);

        IF @Verbose = 1
        BEGIN
            DECLARE @FilasRaw INT = (SELECT COUNT(*) FROM #Raw);
            DECLARE @Det1 NVARCHAR(4000) = CONCAT(N'filas_csv=', CONVERT(NVARCHAR(20), @FilasRaw));
            EXEC reportes.Sp_LogReporte
                 @Procedimiento = @Procedimiento,
                 @Tipo          = 'INFO',
                 @Mensaje       = N'CSV leído',
                 @Detalle       = @Det1,
                 @RutaArchivo   = @RutaArchivo,
                 @RutaLog       = @LogPath;
        END

        /* 2) STAGING: normalizar CBU/CVU (22 dígitos) y mapear inquilino */
        IF OBJECT_ID('tempdb..#Stg','U') IS NOT NULL DROP TABLE #Stg;
        CREATE TABLE #Stg
        (
            cbu_cvu     CHAR(22)     COLLATE DATABASE_DEFAULT NOT NULL,
            esInquilino BIT          NOT NULL,
            dni         INT          NULL,
            nombre      VARCHAR(100) COLLATE DATABASE_DEFAULT NULL,
            apellido    VARCHAR(100) COLLATE DATABASE_DEFAULT NULL,
            email       VARCHAR(255) COLLATE DATABASE_DEFAULT NULL,
            telefono    VARCHAR(50)  COLLATE DATABASE_DEFAULT NULL
        );

        ;WITH s AS
        (
            SELECT
                cbu_raw = LTRIM(RTRIM([CVU/CBU])),
                inq_raw = LTRIM(RTRIM([Inquilino])),
                dni_raw = LTRIM(RTRIM([DNI])),
                nom_raw = LTRIM(RTRIM([Nombre])),
                ape_raw = LTRIM(RTRIM([apellido])),
                mail_raw= LTRIM(RTRIM([email personal])),
                tel_raw = LTRIM(RTRIM([telfono de contacto]))
            FROM #Raw
        ),
        n AS
        (
            SELECT
                cbu_norm =
                    REPLACE(REPLACE(REPLACE(REPLACE(REPLACE(REPLACE(REPLACE(REPLACE(REPLACE(REPLACE(
                        s.cbu_raw,' ',''),'-',''),'.',''),'/',''),'\',''),'_',''),
                        '(' ,''),')',''),CHAR(9),''),CHAR(160),''),
                inq_norm = LOWER(s.inq_raw),
                dni_norm = TRY_CONVERT(INT, NULLIF(s.dni_raw,'')),
                nom_norm = NULLIF(s.nom_raw,''),
                ape_norm = NULLIF(s.ape_raw,''),
                mail_norm= NULLIF(s.mail_raw,''),
                tel_norm =
                    NULLIF(REPLACE(REPLACE(REPLACE(REPLACE(s.tel_raw,' ',''),'-',''),'(',''),')',''), '')
            FROM s
        )
        INSERT INTO #Stg (cbu_cvu, esInquilino, dni, nombre, apellido, email, telefono)
        SELECT DISTINCT
            CONVERT(CHAR(22), n.cbu_norm),
            CASE 
                WHEN n.inq_norm COLLATE DATABASE_DEFAULT IN (N'si',N'sí',N'true',N'1',N'inquilino') THEN 1
                WHEN n.inq_norm COLLATE DATABASE_DEFAULT IN (N'no',N'false',N'0',N'propietario') THEN 0
            END,
            n.dni_norm,
            CASE WHEN n.nom_norm  IS NULL THEN NULL ELSE LEFT(n.nom_norm ,100) END,
            CASE WHEN n.ape_norm  IS NULL THEN NULL ELSE LEFT(n.ape_norm ,100) END,
			CASE
                WHEN n.mail_norm IS NULL THEN NULL
                WHEN importacion.fn_EmailValido(n.mail_norm) = 1
                     THEN LEFT(n.mail_norm, 255)
                ELSE NULL
            END,
			CASE WHEN n.tel_norm  IS NULL THEN NULL ELSE LEFT(n.tel_norm ,50)  END
        FROM n
        WHERE n.cbu_norm IS NOT NULL
          AND LEN(n.cbu_norm)=22
          AND n.cbu_norm NOT LIKE '%[^0-9]%'
          AND n.inq_norm IS NOT NULL
          AND n.inq_norm COLLATE DATABASE_DEFAULT IN
              (N'si',N'sí',N'true',N'1',N'inquilino', N'no',N'false',N'0',N'propietario');

        IF @Verbose = 1
        BEGIN
            DECLARE @FilasStg INT = (SELECT COUNT(*) FROM #Stg);
            DECLARE @Det2 NVARCHAR(4000) = CONCAT(N'filas_stg_validas=', CONVERT(NVARCHAR(20), @FilasStg));
            EXEC reportes.Sp_LogReporte
                 @Procedimiento = @Procedimiento,
                 @Tipo          = 'INFO',
                 @Mensaje       = N'STG listo',
                 @Detalle       = @Det2,
                 @RutaArchivo   = @RutaArchivo,
                 @RutaLog       = @LogPath;
        END

        /* 3) INSERTAR faltantes en app.Tbl_Persona (usa IDX_CVU_CBU_PERSONA) */
        DECLARE @ColsTarget NVARCHAR(MAX) = N'CBU_CVU';
        DECLARE @ColsSource NVARCHAR(MAX) = N's.cbu_cvu';

        IF EXISTS (SELECT 1 FROM sys.columns WHERE object_id = OBJECT_ID('app.Tbl_Persona') AND name = 'dni')
        BEGIN
            SET @ColsTarget = CONCAT(@ColsTarget, N', dni');
            SET @ColsSource = CONCAT(@ColsSource, N', s.dni');
        END

        IF EXISTS (SELECT 1 FROM sys.columns WHERE object_id = OBJECT_ID('app.Tbl_Persona') AND name = 'nombre')
        BEGIN
            SET @ColsTarget = CONCAT(@ColsTarget, N', nombre');
            SET @ColsSource = CONCAT(@ColsSource, N', s.nombre');
        END

        IF EXISTS (SELECT 1 FROM sys.columns WHERE object_id = OBJECT_ID('app.Tbl_Persona') AND name = 'apellido')
        BEGIN
            SET @ColsTarget = CONCAT(@ColsTarget, N', apellido');
            SET @ColsSource = CONCAT(@ColsSource, N', s.apellido');
        END

        IF EXISTS (SELECT 1 FROM sys.columns WHERE object_id = OBJECT_ID('app.Tbl_Persona') AND name = 'email')
        BEGIN
            SET @ColsTarget = CONCAT(@ColsTarget, N', email');
            SET @ColsSource = CONCAT(@ColsSource, N', s.email');
        END

        IF EXISTS (SELECT 1 FROM sys.columns WHERE object_id = OBJECT_ID('app.Tbl_Persona') AND name = 'telefono')
        BEGIN
            SET @ColsTarget = CONCAT(@ColsTarget, N', telefono');
            SET @ColsSource = CONCAT(@ColsSource, N', s.telefono');
        END

        DECLARE @SqlInsPer NVARCHAR(MAX) =
    CONCAT(
        N'INSERT INTO app.Tbl_Persona (', @ColsTarget, N') ',
        N'SELECT ', @ColsSource, N' ',
        N'FROM #Stg s ',
        N'WHERE NOT EXISTS (SELECT 1 FROM app.Tbl_Persona p WHERE p.CBU_CVU = s.cbu_cvu);'
    );

        EXEC (@SqlInsPer);

        IF @Verbose = 1
        BEGIN
            DECLARE @NuevasPersonas INT =
                (SELECT COUNT(*) FROM #Stg s
                 WHERE NOT EXISTS (SELECT 1 FROM app.Tbl_Persona p WHERE p.CBU_CVU = s.cbu_cvu));
            DECLARE @Det3 NVARCHAR(4000) = CONCAT(N'personas_nuevas=', CONVERT(NVARCHAR(20), @NuevasPersonas));
            EXEC reportes.Sp_LogReporte
                 @Procedimiento = @Procedimiento,
                 @Tipo          = 'INFO',
                 @Mensaje       = N'Personas insertadas (faltantes)',
                 @Detalle       = @Det3,
                 @RutaArchivo   = @RutaArchivo,
                 @RutaLog       = @LogPath;
        END

        /* 4) VINCULAR Persona y Consorcio por el MISMO CBU_CVU y upsert en UFPersona (sin idUnidadFuncional) */
IF OBJECT_ID('tempdb.#MatchCBU','U') IS NOT NULL DROP TABLE #MatchCBU;
CREATE TABLE #MatchCBU
(
    idPersona    INT NOT NULL,
    idConsorcio  INT NOT NULL,
    esInquilino  BIT NOT NULL
);

INSERT INTO #MatchCBU (idPersona, idConsorcio, esInquilino)
SELECT
    p.idPersona,
    u.idConsorcio,
    s.esInquilino
FROM #Stg s
JOIN app.Tbl_Persona p ON p.CBU_CVU = s.cbu_cvu
JOIN app.Tbl_UnidadFuncional u WITH (INDEX = UQ_UnidadFuncional_CBU_CVU) ON u.CBU_CVU = s.cbu_cvu;

IF @Verbose = 1
BEGIN
    DECLARE @Det4 NVARCHAR(4000) = CONCAT(N'matcheos_cbu=', (SELECT COUNT(*) FROM #MatchCBU));
    EXEC reportes.Sp_LogReporte @Procedimiento, 'INFO', N'Match Persona↔Consorcio por CBU', @Det4, @RutaArchivo, @LogPath;
END

-- UPDATE si ya existe (idPersona + idConsorcio)
UPDATE uf
   SET uf.esInquilino = m.esInquilino
FROM app.Tbl_UFPersona uf
JOIN #MatchCBU m
  ON m.idPersona = uf.idPersona
 AND m.idConsorcio = uf.idConsorcio;

DECLARE @RowsUpd INT = @@ROWCOUNT;

-- INSERT si no existe (idPersona + idConsorcio)
INSERT INTO app.Tbl_UFPersona (idPersona, idConsorcio, esInquilino, fechaInicio, fechaFin)
SELECT m.idPersona, m.idConsorcio, m.esInquilino, NULL, NULL
FROM #MatchCBU m
WHERE NOT EXISTS (
    SELECT 1
    FROM app.Tbl_UFPersona uf
    WHERE uf.idPersona   = m.idPersona
      AND uf.idConsorcio = m.idConsorcio
);

DECLARE @RowsIns INT = @@ROWCOUNT;

        /* 5) Resumen */
        DECLARE @TotCsv INT = (SELECT COUNT(*) FROM #Raw);
        DECLARE @TotStg INT = (SELECT COUNT(*) FROM #Stg);
        DECLARE @TotMatchCBU INT = (SELECT COUNT(*) FROM #MatchCBU);

        IF @Verbose = 1
        BEGIN
            DECLARE @Det5 NVARCHAR(4000) =
                CONCAT(N'csv=', @TotCsv,
                       N'; stg=', @TotStg,
                       N'; match_cbu=', @TotMatchCBU,
                       N'; uf_upd=', @RowsUpd,
                       N'; uf_ins=', @RowsIns);
            EXEC reportes.Sp_LogReporte
                 @Procedimiento = @Procedimiento,
                 @Tipo          = 'INFO',
                 @Mensaje       = N'Fin OK',
                 @Detalle       = @Det5,
                 @RutaArchivo   = @RutaArchivo,
                 @RutaLog       = @LogPath;
        END

        SELECT
            filas_csv_total           = @TotCsv,
            filas_validas_stg         = @TotStg,
            vinculos_por_cbu          = @TotMatchCBU,
            uf_actualizadas           = @RowsUpd,
            uf_insertadas             = @RowsIns,
            mensaje                   = N'OK';
    END TRY
    BEGIN CATCH
        DECLARE @MsgError NVARCHAR(4000) = ERROR_MESSAGE();
        DECLARE @DetErr NVARCHAR(4000) = CONCAT(N'Error en línea ', CONVERT(NVARCHAR(10), ERROR_LINE()));
        EXEC reportes.Sp_LogReporte
            @Procedimiento = @Procedimiento,
            @Tipo          = 'ERROR',
            @Mensaje       = @DetErr,
            @Detalle       = @MsgError,
            @RutaArchivo   = @RutaArchivo,
            @RutaLog       = @LogPath;
        THROW;
    END CATCH
END
GO
-- //////////////////////////////////////////////////////////////////////
CREATE OR ALTER PROCEDURE importacion.Sp_CargarGastosDesdeJson
    @RutaArchivo NVARCHAR(4000),
    @Anio        INT,
    @DiaVto1     TINYINT = 10,
    @DiaVto2     TINYINT = 20,
    @LogPath     NVARCHAR(4000) = NULL,   -- igual que en otros SPs
    @Verbose     BIT = 1                  -- 1 = loggea INFO
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @Procedimiento SYSNAME = N'importacion.Sp_CargarGastosDesdeJson';

    BEGIN TRY
        IF @Verbose = 1
            EXEC reportes.Sp_LogReporte @Procedimiento, 'INFO', N'Inicio del proceso', NULL, @RutaArchivo, @LogPath;

        /* 1) Leer JSON completo */
        DECLARE @json NVARCHAR(MAX);
        DECLARE @RutaEsc NVARCHAR(4000) = REPLACE(@RutaArchivo, N'''', N'''''');

        DECLARE @sql NVARCHAR(MAX) =
        N'SELECT @jsonOut = BulkColumn
          FROM OPENROWSET (BULK ''' + @RutaEsc + N''', SINGLE_CLOB) AS j;';

        EXEC sp_executesql
             @sql,
             N'@jsonOut NVARCHAR(MAX) OUTPUT',
             @jsonOut = @json OUTPUT;

        IF @json IS NULL
        BEGIN
            DECLARE @DetErrJson NVARCHAR(4000) = N'No se pudo leer el JSON con OPENROWSET.';
            EXEC reportes.Sp_LogReporte @Procedimiento, 'ERROR', N'Lectura JSON', @DetErrJson, @RutaArchivo, @LogPath;
            RAISERROR(N'No se pudo leer el archivo JSON con OPENROWSET. Verificá ruta/permisos y que Ad Hoc Distributed Queries esté habilitado.', 16, 1);
            RETURN;
        END

        IF @Verbose = 1
            EXEC reportes.Sp_LogReporte @Procedimiento, 'INFO', N'JSON leído', N'OK', @RutaArchivo, @LogPath;

        /* 2) Staging */
        IF OBJECT_ID('tempdb..#stg_gasto') IS NOT NULL DROP TABLE #stg_gasto;
        CREATE TABLE #stg_gasto
        (
            consorcio   NVARCHAR(200) COLLATE DATABASE_DEFAULT NOT NULL,
            mes_raw     NVARCHAR(50)  COLLATE DATABASE_DEFAULT NOT NULL,
            mes         TINYINT       NULL,
            categoria   NVARCHAR(100) COLLATE DATABASE_DEFAULT NOT NULL,
            importe_raw NVARCHAR(100) COLLATE DATABASE_DEFAULT NULL,
            importe     DECIMAL(18,2) NULL
        );

        ;WITH rows AS (
            SELECT CAST([value] AS NVARCHAR(MAX)) AS obj
            FROM OPENJSON(@json)
        ),
        base AS (
            SELECT
                JSON_VALUE(obj, '$."Nombre del consorcio"') AS consorcio,
                JSON_VALUE(obj, '$."Mes"')                  AS mes_raw,
                obj
            FROM rows
        ),
        unpvt AS (
            SELECT 
                b.consorcio,
                b.mes_raw,
                v.categoria,
                v.importe_raw
            FROM base b
            CROSS APPLY ( VALUES
                (N'BANCARIOS',               JSON_VALUE(b.obj, '$."BANCARIOS"')),
                (N'LIMPIEZA',                JSON_VALUE(b.obj, '$."LIMPIEZA"')),
                (N'ADMINISTRACION',          JSON_VALUE(b.obj, '$."ADMINISTRACION"')),
                (N'SEGUROS',                 JSON_VALUE(b.obj, '$."SEGUROS"')),
                (N'GASTOS GENERALES',        JSON_VALUE(b.obj, '$."GASTOS GENERALES"')),
                (N'SERVICIOS PUBLICOS-Agua', JSON_VALUE(b.obj, '$."SERVICIOS PUBLICOS-Agua"')),
                (N'SERVICIOS PUBLICOS-Luz',  JSON_VALUE(b.obj, '$."SERVICIOS PUBLICOS-Luz"'))
            ) AS v(categoria, importe_raw)
        )
        INSERT INTO #stg_gasto (consorcio, mes_raw, categoria, importe_raw, mes, importe)
        SELECT
            LTRIM(RTRIM(consorcio))         COLLATE DATABASE_DEFAULT,
            LTRIM(RTRIM(mes_raw))           COLLATE DATABASE_DEFAULT,
            v.categoria                     COLLATE DATABASE_DEFAULT,
            LTRIM(RTRIM(importe_raw))       COLLATE DATABASE_DEFAULT,
            CASE 
                WHEN LOWER(LTRIM(RTRIM(mes_raw))) IN (N'enero')      THEN 1
                WHEN LOWER(LTRIM(RTRIM(mes_raw))) IN (N'febrero')    THEN 2
                WHEN LOWER(LTRIM(RTRIM(mes_raw))) IN (N'marzo')      THEN 3
                WHEN LOWER(LTRIM(RTRIM(mes_raw))) IN (N'abril')      THEN 4
                WHEN LOWER(REPLACE(mes_raw,' ','')) LIKE N'mayo%'    THEN 5
                WHEN LOWER(LTRIM(RTRIM(mes_raw))) IN (N'junio')      THEN 6
                WHEN LOWER(LTRIM(RTRIM(mes_raw))) IN (N'julio')      THEN 7
                WHEN LOWER(LTRIM(RTRIM(mes_raw))) IN (N'agosto')     THEN 8
                WHEN LOWER(LTRIM(RTRIM(mes_raw))) IN (N'septiembre') THEN 9
                WHEN LOWER(LTRIM(RTRIM(mes_raw))) IN (N'octubre')    THEN 10
                WHEN LOWER(LTRIM(RTRIM(mes_raw))) IN (N'noviembre')  THEN 11
                WHEN LOWER(LTRIM(RTRIM(mes_raw))) IN (N'diciembre')  THEN 12
            END,
            CASE 
                WHEN importe_raw IS NULL OR importe_raw = N'' THEN NULL
                ELSE importacion.fn_ParseImporteFlexible(importe_raw)
            END
        FROM unpvt v
        WHERE NULLIF(LTRIM(RTRIM(consorcio)), N'') IS NOT NULL;

        DECLARE @Stg INT = (SELECT COUNT(*) FROM #stg_gasto);
        IF @Verbose = 1
        BEGIN
            DECLARE @DetStg NVARCHAR(4000) = N'filas_stg=' + CONVERT(NVARCHAR(20), @Stg);
            EXEC reportes.Sp_LogReporte @Procedimiento, 'INFO', N'STG cargado', @DetStg, @RutaArchivo, @LogPath;
        END

        IF EXISTS (SELECT 1 FROM #stg_gasto WHERE importe_raw IS NOT NULL AND importe IS NULL)
            EXEC reportes.Sp_LogReporte @Procedimiento, 'WARN', N'Importes no convertidos', N'Hay importes con NULL tras parseo', @RutaArchivo, @LogPath;

        /* 3) Mapa de extraordinarios (editable) */
        IF OBJECT_ID('tempdb..#map_extra') IS NOT NULL DROP TABLE #map_extra;
        CREATE TABLE #map_extra (categoria NVARCHAR(100) COLLATE DATABASE_DEFAULT PRIMARY KEY);
        INSERT INTO #map_extra(categoria) VALUES (N'GASTOS GENERALES');

        /* 4) Consorcios: crear los faltantes */
        ;WITH cte_cons AS (
            SELECT DISTINCT consorcio
            FROM #stg_gasto
            WHERE consorcio IS NOT NULL AND consorcio <> N''
        )
        INSERT INTO app.Tbl_Consorcio (nombre, direccion, superficieTotal)
        SELECT c.consorcio, NULL, NULL
        FROM cte_cons c
        LEFT JOIN app.Tbl_Consorcio tc
               ON tc.nombre = c.consorcio COLLATE DATABASE_DEFAULT
        WHERE tc.idConsorcio IS NULL;

        DECLARE @ConsCreados INT = @@ROWCOUNT;
        IF @Verbose = 1
        BEGIN
            DECLARE @DetCons NVARCHAR(4000) = N'consorcios_creados=' + CONVERT(NVARCHAR(20), @ConsCreados);
            EXEC reportes.Sp_LogReporte @Procedimiento, 'INFO', N'Consorcios creados', @DetCons, @RutaArchivo, @LogPath;
        END

        IF OBJECT_ID('tempdb..#cons') IS NOT NULL DROP TABLE #cons;
        SELECT c.consorcio, tc.idConsorcio
        INTO #cons
        FROM (SELECT DISTINCT consorcio FROM #stg_gasto) c
        INNER JOIN app.Tbl_Consorcio tc
                ON tc.nombre = c.consorcio COLLATE DATABASE_DEFAULT;

        /* 5) Totales por Consorcio+Mes */
        IF OBJECT_ID('tempdb..#exp_sum') IS NOT NULL DROP TABLE #exp_sum;
        SELECT cn.idConsorcio, s.mes, SUM(s.importe) AS total
        INTO #exp_sum
        FROM #stg_gasto s
        INNER JOIN #cons cn ON cn.consorcio = s.consorcio COLLATE DATABASE_DEFAULT
        WHERE s.importe IS NOT NULL AND s.mes BETWEEN 1 AND 12
        GROUP BY cn.idConsorcio, s.mes;

        DECLARE @RowsSum INT = (SELECT COUNT(*) FROM #exp_sum);
        IF @Verbose = 1
        BEGIN
            DECLARE @DetSum NVARCHAR(4000) = N'grupos_consorcio_mes=' + CONVERT(NVARCHAR(20), @RowsSum);
            EXEC reportes.Sp_LogReporte @Procedimiento, 'INFO', N'Totales por mes', @DetSum, @RutaArchivo, @LogPath;
        END

        /* 6) Crear/Actualizar Expensas (SET-BASED, sin cursor, con clamp a DEC(10,2)) */
        IF OBJECT_ID('tempdb..#exp') IS NOT NULL DROP TABLE #exp;
        IF OBJECT_ID('tempdb..#merge_out') IS NOT NULL DROP TABLE #merge_out;
        CREATE TABLE #merge_out(accion NVARCHAR(10));

        ;WITH calc AS (
            -- Partimos de #exp_sum (idConsorcio, mes, total)
            SELECT
                es.idConsorcio,
                es.mes,
                es.total,
                -- 5° día hábil del mes
                fechaGeneracion =
                (
                    SELECT MAX(d)
                    FROM (
                        SELECT TOP (5)
                               DATEADD(DAY, v.n, DATEFROMPARTS(@Anio, es.mes, 1)) AS d
                        FROM (VALUES (0),(1),(2),(3),(4),(5),(6),(7),(8),(9),(10),(11),(12),(13)) v(n)
                        WHERE DATENAME(WEEKDAY,
                                       DATEADD(DAY, v.n, DATEFROMPARTS(@Anio, es.mes, 1))) NOT IN ('Saturday', 'Sunday')
                        ORDER BY d
                    ) q
                ),
                finMes = EOMONTH(DATEFROMPARTS(@Anio, es.mes, 1))
            FROM #exp_sum es
        ),
        src AS (
            SELECT
                c.idConsorcio,
                c.mes,
                c.fechaGeneracion,
                vto1 = CASE 
                         WHEN @DiaVto1 IS NULL THEN c.finMes
                         ELSE DATEFROMPARTS(YEAR(c.fechaGeneracion), MONTH(c.fechaGeneracion),
                                            IIF(@DiaVto1 > DAY(c.finMes), DAY(c.finMes), @DiaVto1))
                       END,
                vto2 = CASE 
                         WHEN @DiaVto2 IS NULL THEN c.finMes
                         ELSE DATEFROMPARTS(YEAR(c.fechaGeneracion), MONTH(c.fechaGeneracion),
                                            IIF(@DiaVto2 > DAY(c.finMes), DAY(c.finMes), @DiaVto2))
                       END,
                -- clamp a DEC(10,2) para respetar Tbl_Expensa.montoTotal
                montoTotal = CAST(CASE 
                                    WHEN c.total >  99999999.99 THEN  99999999.99
                                    WHEN c.total < -99999999.99 THEN -99999999.99
                                    ELSE c.total
                                  END AS DECIMAL(10,2))
            FROM calc c
        )
        MERGE app.Tbl_Expensa AS T
        USING src AS S
           ON T.idConsorcio     = S.idConsorcio
          AND T.fechaGeneracion = S.fechaGeneracion
        WHEN MATCHED THEN
            UPDATE SET T.fechaVto1  = S.vto1,
                       T.fechaVto2  = S.vto2,
                       T.montoTotal = S.montoTotal
        WHEN NOT MATCHED THEN
            INSERT (idConsorcio, fechaGeneracion, fechaVto1, fechaVto2, montoTotal)
            VALUES (S.idConsorcio, S.fechaGeneracion, S.vto1, S.vto2, S.montoTotal)
        OUTPUT $action INTO #merge_out;

        -- métricas de expensas
        DECLARE @ExpensasCreadas INT      = (SELECT COUNT(*) FROM #merge_out WHERE accion = 'INSERT');
        DECLARE @ExpensasActualizadas INT = (SELECT COUNT(*) FROM #merge_out WHERE accion = 'UPDATE');

        -- reconstruimos #exp (idConsorcio, mes, nroExpensa) por año+mes
        SELECT s.idConsorcio,
               s.mes,
               e.nroExpensa
        INTO #exp
        FROM #exp_sum s
        JOIN app.Tbl_Expensa e
          ON e.idConsorcio = s.idConsorcio
         AND YEAR(e.fechaGeneracion)  = @Anio
         AND MONTH(e.fechaGeneracion) = s.mes;

        IF @Verbose = 1
        BEGIN
            DECLARE @DetExp NVARCHAR(4000) =
                N'expensas_creadas=' + CONVERT(NVARCHAR(20), @ExpensasCreadas) +
                N'; expensas_actualizadas=' + CONVERT(NVARCHAR(20), @ExpensasActualizadas);
            EXEC reportes.Sp_LogReporte @Procedimiento, 'INFO', N'Expensas procesadas', @DetExp, @RutaArchivo, @LogPath;
        END

        /* 7) Insertar Gastos + capturar categorías (importe clamped a DEC(10,2)) */
        IF OBJECT_ID('tempdb..#ins') IS NOT NULL DROP TABLE #ins;
        CREATE TABLE #ins
        (
            idGasto   INT NOT NULL,
            categoria NVARCHAR(100) COLLATE DATABASE_DEFAULT NOT NULL
        );

        MERGE app.Tbl_Gasto AS tgt
        USING (
            SELECT 
                e.nroExpensa                                                    AS nroExpensa,
                c.idConsorcio                                                   AS idConsorcio,
                /* tipar + collation para evitar conflictos */
                CAST(CASE WHEN mx.categoria IS NOT NULL 
                          THEN 'Extraordinario' ELSE 'Ordinario' END AS VARCHAR(16)) COLLATE DATABASE_DEFAULT AS tipo,
                s.categoria                                                     AS descripcion,   -- literal desde JSON
                DATEFROMPARTS(@Anio, s.mes, 1)                                  AS fechaEmision,
                /* clamp + cast para respetar DEC(10,2) de Tbl_Gasto.importe */
                CAST(CASE 
                        WHEN s.importe >  99999999.99 THEN  99999999.99
                        WHEN s.importe < -99999999.99 THEN -99999999.99
                        ELSE s.importe
                    END AS DECIMAL(10,2))                                       AS importe,
                s.categoria                                                     AS categoria
            FROM #stg_gasto s
            INNER JOIN #cons c  ON c.consorcio = s.consorcio COLLATE DATABASE_DEFAULT
            INNER JOIN #exp e   ON e.idConsorcio = c.idConsorcio AND e.mes = s.mes
            LEFT  JOIN #map_extra mx ON mx.categoria = s.categoria COLLATE DATABASE_DEFAULT
            WHERE s.importe IS NOT NULL AND s.mes BETWEEN 1 AND 12
        ) AS src
        ON  tgt.idConsorcio = src.idConsorcio
        AND tgt.nroExpensa  = src.nroExpensa
        AND tgt.tipo        = src.tipo
        AND ISNULL(tgt.descripcion,'') = ISNULL(src.descripcion,'')
        WHEN NOT MATCHED THEN
            INSERT (nroExpensa, idConsorcio, tipo, descripcion, fechaEmision, importe)
            VALUES (src.nroExpensa, src.idConsorcio, src.tipo, src.descripcion, src.fechaEmision, src.importe)
        OUTPUT INSERTED.idGasto, src.categoria INTO #ins(idGasto, categoria);

        DECLARE @GastosInsertados INT = (SELECT COUNT(*) FROM #ins);
        IF @Verbose = 1
        BEGIN
            DECLARE @DetG NVARCHAR(4000) = N'gastos_insertados=' + CONVERT(NVARCHAR(20), @GastosInsertados);
            EXEC reportes.Sp_LogReporte @Procedimiento, 'INFO', N'Gastos insertados', @DetG, @RutaArchivo, @LogPath;
        END

        /* 8) Subtablas */
        INSERT INTO app.Tbl_Gasto_Ordinario (idGasto, nombreProveedor, categoria, nroFactura)
        SELECT i.idGasto, NULL, i.categoria, NULL
        FROM #ins i
        LEFT JOIN #map_extra mx ON mx.categoria = i.categoria COLLATE DATABASE_DEFAULT
        WHERE mx.categoria IS NULL;

        DECLARE @OrdIns INT = @@ROWCOUNT;

        INSERT INTO app.Tbl_Gasto_Extraordinario (idGasto, cuotaActual, cantCuotas)
        SELECT i.idGasto, 1, 1
        FROM #ins i
        INNER JOIN #map_extra mx ON mx.categoria = i.categoria COLLATE DATABASE_DEFAULT;

        DECLARE @ExtIns INT = @@ROWCOUNT;

        IF @Verbose = 1
        BEGIN
            DECLARE @DetSub NVARCHAR(4000) =
                N'ordinarios=' + CONVERT(NVARCHAR(20), @OrdIns) +
                N'; extraordinarios=' + CONVERT(NVARCHAR(20), @ExtIns);
            EXEC reportes.Sp_LogReporte @Procedimiento, 'INFO', N'Subtablas cargadas', @DetSub, @RutaArchivo, @LogPath;
        END

        /* 9) Fin + resumen */
        DECLARE @Resumen NVARCHAR(4000) =
            N'stg=' + CONVERT(NVARCHAR(20), @Stg) +
            N'; cons_creados=' + CONVERT(NVARCHAR(20), @ConsCreados) +
            N'; exp_creadas=' + CONVERT(NVARCHAR(20), @ExpensasCreadas) +
            N'; exp_actualizadas=' + CONVERT(NVARCHAR(20), @ExpensasActualizadas) +
            N'; gastos=' + CONVERT(NVARCHAR(20), @GastosInsertados) +
            N'; ord=' + CONVERT(NVARCHAR(20), @OrdIns) +
            N'; ext=' + CONVERT(NVARCHAR(20), @ExtIns);

        IF @Verbose = 1
            EXEC reportes.Sp_LogReporte @Procedimiento, 'INFO', N'Fin OK', @Resumen, @RutaArchivo, @LogPath;

        SELECT
            filas_stg                  = @Stg,
            consorcios_creados         = @ConsCreados,
            expensas_creadas           = @ExpensasCreadas,
            expensas_actualizadas      = @ExpensasActualizadas,
            gastos_insertados          = @GastosInsertados,
            ordinarios_insertados      = @OrdIns,
            extraordinarios_insertados = @ExtIns,
            mensaje                    = N'OK';
    END TRY
    BEGIN CATCH
        DECLARE @MsgError NVARCHAR(4000) = ERROR_MESSAGE();
        DECLARE @DetErr  NVARCHAR(4000) = N'Error en línea ' + CONVERT(NVARCHAR(10), ERROR_LINE());
        EXEC reportes.Sp_LogReporte
            @Procedimiento = @Procedimiento,
            @Tipo          = 'ERROR',
            @Mensaje       = @DetErr,
            @Detalle       = @MsgError,
            @RutaArchivo   = @RutaArchivo,
            @RutaLog       = @LogPath;
        THROW;
    END CATCH
END
GO
-- //////////////////////////////////////////////////////////////////////
-- Cargar un insert de lote de expensas y estado cuenta
-- //////////////////////////////////////////////////////////////////////
IF OBJECT_ID('importacion.Tbl_PagoNoAsociado', 'U') IS NULL
BEGIN
    CREATE TABLE importacion.Tbl_PagoNoAsociado
    (
        idPagoNoAsociado INT IDENTITY(1,1) PRIMARY KEY,
        fechaRegistro    DATETIME2(0) NOT NULL CONSTRAINT DF_PagoNoAsoc_fechaRegistro DEFAULT SYSDATETIME(),
        motivo           NVARCHAR(200)  COLLATE DATABASE_DEFAULT NULL,
        fecha_txt        NVARCHAR(4000) COLLATE DATABASE_DEFAULT NULL,
        cbu_txt          NVARCHAR(4000) COLLATE DATABASE_DEFAULT NULL,
        valor_txt        NVARCHAR(4000) COLLATE DATABASE_DEFAULT NULL,
        rutaArchivo      NVARCHAR(4000) COLLATE DATABASE_DEFAULT NULL
    );
END
GO

CREATE OR ALTER PROCEDURE importacion.Sp_CargarPagosDesdeCsv
    @RutaArchivo      NVARCHAR(4000),
    @HDR              BIT           = 1,
    @Separador        CHAR(1)       = ',',
    @RowTerminator    NVARCHAR(10)  = N'0x0d0a',
    @CodePage         NVARCHAR(16)  = N'65001',
    @LogPath          NVARCHAR(4000) = NULL,
    @Verbose          BIT           = 1
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @Procedimiento SYSNAME = N'importacion.Sp_CargarPagosDesdeCsv';

    BEGIN TRY
        /* =============================== 0) INICIO =============================== */
        IF @Verbose = 1
            EXEC reportes.Sp_LogReporte @Procedimiento, 'INFO',
                 N'Inicio del proceso', NULL, @RutaArchivo, @LogPath;

        /* Limpieza previa */
        IF OBJECT_ID('tempdb..#raw')             IS NOT NULL DROP TABLE #raw;
        IF OBJECT_ID('tempdb..#norm')            IS NOT NULL DROP TABLE #norm;
        IF OBJECT_ID('tempdb..#pagos')           IS NOT NULL DROP TABLE #pagos;
        IF OBJECT_ID('tempdb..#errores')         IS NOT NULL DROP TABLE #errores;
        IF OBJECT_ID('tempdb..#pagos_completos') IS NOT NULL DROP TABLE #pagos_completos;
        IF OBJECT_ID('tempdb..#ok')              IS NOT NULL DROP TABLE #ok;

        /* Tablas temporales */
        CREATE TABLE #raw (
            c1 NVARCHAR(4000) COLLATE DATABASE_DEFAULT NULL,
            c2 NVARCHAR(4000) COLLATE DATABASE_DEFAULT NULL,
            c3 NVARCHAR(4000) COLLATE DATABASE_DEFAULT NULL,
            c4 NVARCHAR(4000) COLLATE DATABASE_DEFAULT NULL,
            c5 NVARCHAR(4000) COLLATE DATABASE_DEFAULT NULL,
            c6 NVARCHAR(4000) COLLATE DATABASE_DEFAULT NULL
        );

        CREATE TABLE #norm (
            id_pago_txt NVARCHAR(4000) COLLATE DATABASE_DEFAULT NULL,
            fecha_txt   NVARCHAR(4000) COLLATE DATABASE_DEFAULT NULL,
            cbu_txt     NVARCHAR(4000) COLLATE DATABASE_DEFAULT NULL,
            valor_txt   NVARCHAR(4000) COLLATE DATABASE_DEFAULT NULL
        );

        CREATE TABLE #pagos (
            fecha       DATE          NOT NULL,
            CBU_CVU     VARCHAR(22)   COLLATE DATABASE_DEFAULT NOT NULL,
            valor       DECIMAL(10,2) NOT NULL
        );

        CREATE TABLE #errores (
            motivo      NVARCHAR(200)  COLLATE DATABASE_DEFAULT,
            fecha_txt   NVARCHAR(4000) COLLATE DATABASE_DEFAULT,
            cbu_txt     NVARCHAR(4000) COLLATE DATABASE_DEFAULT,
            valor_txt   NVARCHAR(4000) COLLATE DATABASE_DEFAULT
        );

        /* =============================== 1) BULK =============================== */
        DECLARE @PrimeraFila INT = CASE WHEN @HDR = 1 THEN 2 ELSE 1 END;
        DECLARE @RutaEsc NVARCHAR(4000) = REPLACE(@RutaArchivo, N'''', N'''''');

        DECLARE @SqlBulk NVARCHAR(MAX) =
            CONCAT(
                N'BULK INSERT #raw FROM ''', @RutaEsc, N''' WITH (',
                N' FIRSTROW = ', CONVERT(NVARCHAR(10), @PrimeraFila),
                N', FIELDTERMINATOR = ''', @Separador, N'''',
                N', ROWTERMINATOR  = ''', @RowTerminator, N'''',
                N', CODEPAGE       = ''', @CodePage, N'''',
                N', TABLOCK );'
            );

        BEGIN TRY
            EXEC (@SqlBulk);
        END TRY
        BEGIN CATCH
            DECLARE @Emsg NVARCHAR(4000) = ERROR_MESSAGE();
            EXEC reportes.Sp_LogReporte @Procedimiento, 'ERROR',
                 N'BULK INSERT', @Emsg, @RutaArchivo, @LogPath;
            THROW;
        END CATCH

        DECLARE @FilasRaw INT = (SELECT COUNT(*) FROM #raw);
        IF @Verbose = 1
        BEGIN
            DECLARE @DetRaw NVARCHAR(4000) =
                CONCAT(N'filas_raw=', CONVERT(NVARCHAR(20), @FilasRaw));
            EXEC reportes.Sp_LogReporte @Procedimiento, 'INFO',
                 N'CSV leído', @DetRaw, @RutaArchivo, @LogPath;
        END

        /* =============================== 2) Normalización =============================== */
        INSERT INTO #norm (id_pago_txt, fecha_txt, cbu_txt, valor_txt)
        SELECT
            CASE WHEN NULLIF(LTRIM(RTRIM(c4)),'') IS NOT NULL THEN c1 ELSE NULL END,
            CASE WHEN NULLIF(LTRIM(RTRIM(c4)),'') IS NOT NULL THEN c2 ELSE c1 END,
            CASE WHEN NULLIF(LTRIM(RTRIM(c4)),'') IS NOT NULL THEN c3 ELSE c2 END,
            CASE WHEN NULLIF(LTRIM(RTRIM(c4)),'') IS NOT NULL THEN c4 ELSE c3 END
        FROM #raw;

        DECLARE @FilasNorm INT = (SELECT COUNT(*) FROM #norm);
        IF @Verbose = 1
        BEGIN
            DECLARE @DetNorm NVARCHAR(4000) =
                CONCAT(N'filas_norm=', CONVERT(NVARCHAR(20), @FilasNorm));
            EXEC reportes.Sp_LogReporte @Procedimiento, 'INFO',
                 N'Normalización lista', @DetNorm, @RutaArchivo, @LogPath;
        END

        /* =============================== 3) Parseo -> #pagos =============================== */
        ;WITH pre AS (
            SELECT
                fecha_txt,
                cbu_txt,
                valor_txt,
                LTRIM(RTRIM(REPLACE(
                    REPLACE(REPLACE(valor_txt, NCHAR(160), N' '), CHAR(9), N' '),
                    N'$',''
                ))) AS v0
            FROM #norm
        ),
        norm_val AS (
            SELECT
                fecha_txt,
                cbu_txt,
                valor_txt,
                REPLACE(REPLACE(v0, N'.', N''), N',', N'.') AS v1
            FROM pre
        ),
        recorte AS (
            SELECT
                fecha_txt, cbu_txt, valor_txt,
                CASE WHEN CHARINDEX(' ', v1) > 0
                     THEN LEFT(v1, CHARINDEX(' ', v1)-1)
                     ELSE v1
                END AS v_num_txt
            FROM norm_val
        ),
        parsed AS (
            SELECT
                COALESCE(
                    TRY_CONVERT(date, NULLIF(LTRIM(RTRIM(fecha_txt)),''), 103), -- dd/mm/yyyy
                    TRY_CONVERT(date, NULLIF(LTRIM(RTRIM(fecha_txt)),''), 120), -- yyyy-mm-dd
                    TRY_CONVERT(date, NULLIF(LTRIM(RTRIM(fecha_txt)),''))      -- genérico
                ) AS fecha,
                LEFT(LTRIM(RTRIM(cbu_txt)), 22) AS CBU_CVU,
                TRY_CONVERT(decimal(10,2), v_num_txt) AS valor
            FROM recorte
        )
        INSERT INTO #pagos (fecha, CBU_CVU, valor)
        SELECT fecha, CBU_CVU, valor
        FROM parsed
        WHERE fecha IS NOT NULL
          AND valor IS NOT NULL
          AND NULLIF(CBU_CVU,'') IS NOT NULL;

        DECLARE @FilasPagos INT = (SELECT COUNT(*) FROM #pagos);
        IF @Verbose = 1
        BEGIN
            DECLARE @DetPagos NVARCHAR(4000) =
                CONCAT(N'pagos_validos=', CONVERT(NVARCHAR(20), @FilasPagos));
            EXEC reportes.Sp_LogReporte @Procedimiento, 'INFO',
                 N'Parseo de pagos', @DetPagos, @RutaArchivo, @LogPath;
        END

        /* Errores de parseo */
        INSERT INTO #errores (motivo, fecha_txt, cbu_txt, valor_txt)
        SELECT
            N'Fila inválida (fecha/valor/CBU)',
            n.fecha_txt, n.cbu_txt, n.valor_txt
        FROM #norm n
        WHERE NOT EXISTS (
            SELECT 1
            FROM #pagos p
            WHERE p.CBU_CVU = LEFT(LTRIM(RTRIM(n.cbu_txt)), 22)
              AND p.fecha = COALESCE(
                                TRY_CONVERT(date, NULLIF(LTRIM(RTRIM(n.fecha_txt)),''), 103),
                                TRY_CONVERT(date, NULLIF(LTRIM(RTRIM(n.fecha_txt)),''), 120),
                                TRY_CONVERT(date, NULLIF(LTRIM(RTRIM(n.fecha_txt)),'')))
        );

        DECLARE @ErroresParseo INT = (SELECT COUNT(*) FROM #errores);
        IF @ErroresParseo > 0 AND @Verbose = 1
        BEGIN
            DECLARE @DetErrParseo NVARCHAR(4000) =
                CONCAT(N'filas_invalidas=', CONVERT(NVARCHAR(20), @ErroresParseo));
            EXEC reportes.Sp_LogReporte @Procedimiento, 'WARN',
                 N'Filas descartadas por parseo', @DetErrParseo, @RutaArchivo, @LogPath;
        END

        /* =============================== 4) Enriquecer (Persona/UF/Consorcio/Expensa) =============================== */
        ;WITH pagos_enriq AS
        (
            SELECT
                p.fecha,
                p.valor                AS monto,
                p.CBU_CVU,
                per.idPersona,
                uf.idUnidadFuncional,
                uf.idConsorcio
            FROM #pagos p
            LEFT JOIN app.Tbl_Persona         per ON per.CBU_CVU = p.CBU_CVU
            LEFT JOIN app.Tbl_UnidadFuncional uf
                   ON uf.CBU_CVU = p.CBU_CVU
        )
        SELECT
            pe.*,
            e.nroExpensa
        INTO #pagos_completos
        FROM pagos_enriq pe
        CROSS APPLY (VALUES (DATEFROMPARTS(YEAR(pe.fecha), MONTH(pe.fecha), 1))) AS m(inicioMes)
        OUTER APPLY
        (
            /* Rango: [primer día del mes, primer día del mes siguiente) */
            SELECT TOP (1) e.nroExpensa
            FROM app.Tbl_Expensa e
            WHERE e.idConsorcio = pe.idConsorcio
              AND e.fechaGeneracion >= m.inicioMes
              AND e.fechaGeneracion <  DATEADD(MONTH, 1, m.inicioMes)
            ORDER BY e.fechaGeneracion DESC, e.nroExpensa DESC
        ) e;

        /* Registrar faltantes de mapeo (persona/UF/consorcio/expensa) */
        INSERT INTO #errores (motivo, fecha_txt, cbu_txt, valor_txt)
        SELECT
            CASE 
              WHEN idPersona IS NULL         THEN N'CBU no existe en Tbl_Persona'
              WHEN idUnidadFuncional IS NULL THEN N'No se encontró UF para ese CBU'
              WHEN idConsorcio IS NULL       THEN N'No se determinó Consorcio'
              WHEN nroExpensa IS NULL        THEN N'No hay expensa del mes para el consorcio'
            END,
            CONVERT(NVARCHAR(30), fecha, 121),
            CBU_CVU,
            CONVERT(NVARCHAR(40), monto)
        FROM #pagos_completos
        WHERE idPersona IS NULL
           OR idUnidadFuncional IS NULL
           OR idConsorcio IS NULL
           OR nroExpensa IS NULL;

        /* Registrar filas sin EstadoCuenta */
        INSERT INTO #errores (motivo, fecha_txt, cbu_txt, valor_txt)
        SELECT
            N'No existe EstadoCuenta para UF/Consorcio/Expensa',
            CONVERT(NVARCHAR(30), p.fecha, 121),
            p.CBU_CVU,
            CONVERT(NVARCHAR(40), p.monto)
        FROM #pagos_completos p
        WHERE p.idPersona IS NOT NULL
          AND p.idUnidadFuncional IS NOT NULL
          AND p.idConsorcio IS NOT NULL
          AND p.nroExpensa IS NOT NULL
          AND NOT EXISTS (
                SELECT 1
                FROM app.Tbl_EstadoCuenta ec
                WHERE ec.nroUnidadFuncional = p.idUnidadFuncional
                  AND ec.idConsorcio       = p.idConsorcio
                  AND ec.nroExpensa        = p.nroExpensa
          );

        /* Filas válidas (con mapeo completo Y EstadoCuenta existente) */
        IF OBJECT_ID('tempdb..#ok') IS NOT NULL DROP TABLE #ok;

        SELECT
            p.fecha,
            p.monto,
            p.CBU_CVU,
            p.idPersona,
            p.idUnidadFuncional,
            p.idConsorcio,
            p.nroExpensa,
            ec.idEstadoCuenta
        INTO #ok
        FROM #pagos_completos p
        JOIN app.Tbl_EstadoCuenta ec
          ON ec.nroUnidadFuncional = p.idUnidadFuncional
         AND ec.idConsorcio       = p.idConsorcio
         AND ec.nroExpensa        = p.nroExpensa
        WHERE p.idPersona IS NOT NULL
          AND p.idUnidadFuncional IS NOT NULL
          AND p.idConsorcio IS NOT NULL
          AND p.nroExpensa IS NOT NULL;

        /* Errores de matching */
        DECLARE @ErroresMatch       INT = (SELECT COUNT(*) FROM #errores) - @ErroresParseo;
        DECLARE @FilasOK           INT = (SELECT COUNT(*) FROM #ok);
        DECLARE @PagosNoAsociados  INT = (SELECT COUNT(*) FROM #errores);

        IF @ErroresMatch > 0 AND @Verbose = 1
        BEGIN
            DECLARE @DetErrMatch NVARCHAR(4000) =
                CONCAT(N'falla_match=', CONVERT(NVARCHAR(20), @ErroresMatch));
            EXEC reportes.Sp_LogReporte @Procedimiento, 'WARN',
                 N'Filas sin mapping completo', @DetErrMatch, @RutaArchivo, @LogPath;
        END

        IF @Verbose = 1
        BEGIN
            DECLARE @DetOK NVARCHAR(4000) =
                CONCAT(N'pagos_ok=', CONVERT(NVARCHAR(20), @FilasOK));
            EXEC reportes.Sp_LogReporte @Procedimiento, 'INFO',
                 N'Filas listas para inserción', @DetOK, @RutaArchivo, @LogPath;
        END

        /* =============================== 4.b) Persistir pagos no asociados =============================== */
        IF OBJECT_ID('importacion.Tbl_PagoNoAsociado', 'U') IS NOT NULL
        BEGIN
            INSERT INTO importacion.Tbl_PagoNoAsociado
                (motivo, fecha_txt, cbu_txt, valor_txt, rutaArchivo)
            SELECT
                motivo, fecha_txt, cbu_txt, valor_txt, @RutaArchivo
            FROM #errores;

            IF @Verbose = 1
            BEGIN
                DECLARE @DetNoAsoc NVARCHAR(4000) =
                    CONCAT(N'pagos_no_asociados=', CONVERT(NVARCHAR(20), @PagosNoAsociados));
                EXEC reportes.Sp_LogReporte @Procedimiento, 'INFO',
                     N'Pagos no asociados registrados', @DetNoAsoc, @RutaArchivo, @LogPath;
            END
        END

        /* =============================== 5) SOLO PAGOS (NO crea EstadoCuenta) =============================== */
        INSERT INTO app.Tbl_Pago
            (idEstadoCuenta, nroUnidadFuncional, idConsorcio, nroExpensa,
             fecha, monto, CBU_CVU)
        SELECT
            o.idEstadoCuenta,
            o.idUnidadFuncional,
            o.idConsorcio,
            o.nroExpensa,
            o.fecha,
            o.monto,
            o.CBU_CVU
        FROM #ok o
        OPTION (USE HINT('DISABLE_OPTIMIZED_PLAN_FORCING'));

        DECLARE @PagosInsertados INT = @@ROWCOUNT;

        IF @Verbose = 1
        BEGIN
            DECLARE @DetPago NVARCHAR(4000) =
                CONCAT(N'pagos_insertados=', CONVERT(NVARCHAR(20), @PagosInsertados));
            EXEC reportes.Sp_LogReporte @Procedimiento, 'INFO',
                 N'Pagos insertados', @DetPago, @RutaArchivo, @LogPath;
        END

        /* =============================== 6) Resumen =============================== */
        DECLARE @Resumen NVARCHAR(4000);
        SET @Resumen =
            CONCAT(
                N'raw=', @FilasRaw,
                N'; norm=', @FilasNorm,
                N'; pagos_validos=', @FilasPagos,
                N'; errores_parseo=', @ErroresParseo,
                N'; errores_match=', @ErroresMatch,
                N'; pagos_no_asociados=', @PagosNoAsociados,
                N'; pagos_listos=', @FilasOK,
                N'; pagos_ins=', @PagosInsertados
            );

        IF @Verbose = 1
            EXEC reportes.Sp_LogReporte @Procedimiento, 'INFO',
                 N'Fin OK', @Resumen, @RutaArchivo, @LogPath;

        SELECT
            filas_raw             = @FilasRaw,
            filas_norm            = @FilasNorm,
            pagos_validos         = @FilasPagos,
            errores_parseo        = @ErroresParseo,
            errores_match         = @ErroresMatch,
            pagos_no_asociados    = @PagosNoAsociados,
            pagos_listos          = @FilasOK,
            pagos_insertados      = @PagosInsertados,
            mensaje               = N'OK';
    END TRY
    BEGIN CATCH
        DECLARE @MsgError NVARCHAR(4000) = ERROR_MESSAGE();
        DECLARE @DetErr  NVARCHAR(4000) =
            CONCAT(N'Error en línea ', CONVERT(NVARCHAR(10), ERROR_LINE()));
        EXEC reportes.Sp_LogReporte
            @Procedimiento = @Procedimiento,
            @Tipo          = 'ERROR',
            @Mensaje       = @DetErr,
            @Detalle       = @MsgError,
            @RutaArchivo   = @RutaArchivo,
            @RutaLog       = @LogPath;
        THROW;
    END CATCH
END
GO
-- //////////////////////////////////////////////////////////////////////
CREATE OR ALTER PROCEDURE app.Sp_CargarGastosExtraordinariosIniciales
    @Verbose BIT = 0
AS
BEGIN
    SET NOCOUNT ON;

    /* 0) Alinear con consorcios de prueba */
    DECLARE
        @idCons_Test1 INT,
        @idCons_Test2 INT,
        @idCons_Test3 INT,
        @idCons_Test4 INT;

    -- Asegurar consorcios de prueba por nombre (se crean si no existen)
    IF NOT EXISTS (SELECT 1 FROM app.Tbl_Consorcio WHERE nombre = 'CONSORCIO_TEST_1_FULL_BC')
        INSERT INTO app.Tbl_Consorcio (nombre, direccion, superficieTotal)
        VALUES ('CONSORCIO_TEST_1_FULL_BC', NULL, NULL);

    IF NOT EXISTS (SELECT 1 FROM app.Tbl_Consorcio WHERE nombre = 'CONSORCIO_TEST_2_SIN_BC')
        INSERT INTO app.Tbl_Consorcio (nombre, direccion, superficieTotal)
        VALUES ('CONSORCIO_TEST_2_SIN_BC', NULL, NULL);

    IF NOT EXISTS (SELECT 1 FROM app.Tbl_Consorcio WHERE nombre = 'CONSORCIO_TEST_3_SOLO_BAULERA')
        INSERT INTO app.Tbl_Consorcio (nombre, direccion, superficieTotal)
        VALUES ('CONSORCIO_TEST_3_SOLO_BAULERA', NULL, NULL);

    IF NOT EXISTS (SELECT 1 FROM app.Tbl_Consorcio WHERE nombre = 'CONSORCIO_TEST_4_SOLO_COCHERA')
        INSERT INTO app.Tbl_Consorcio (nombre, direccion, superficieTotal)
        VALUES ('CONSORCIO_TEST_4_SOLO_COCHERA', NULL, NULL);

    SELECT @idCons_Test1 = idConsorcio
    FROM app.Tbl_Consorcio WHERE nombre = 'CONSORCIO_TEST_1_FULL_BC';

    SELECT @idCons_Test2 = idConsorcio
    FROM app.Tbl_Consorcio WHERE nombre = 'CONSORCIO_TEST_2_SIN_BC';

    SELECT @idCons_Test3 = idConsorcio
    FROM app.Tbl_Consorcio WHERE nombre = 'CONSORCIO_TEST_3_SOLO_BAULERA';

    SELECT @idCons_Test4 = idConsorcio
    FROM app.Tbl_Consorcio WHERE nombre = 'CONSORCIO_TEST_4_SOLO_COCHERA';

    IF OBJECT_ID('tempdb..#GastosTemp') IS NOT NULL DROP TABLE #GastosTemp;
    CREATE TABLE #GastosTemp (
        idConsorcio   INT,
        descripcion   VARCHAR(200) COLLATE DATABASE_DEFAULT,
        fechaEmision  DATE,
        importe       DECIMAL(10,2),
        cuotaActual   TINYINT,
        cantCuotas    TINYINT
    );

    /* Casos de prueba (incluye uno en marzo 2025 para CONSORCIO_TEST_1_FULL_BC) */
    INSERT INTO #GastosTemp (idConsorcio, descripcion, fechaEmision, importe, cuotaActual, cantCuotas)
    VALUES
      -- Este es el que te asegura extraordinarias en la expensa de marzo 2025
      (@idCons_Test1, 'Obra extraordinaria fachada y balcones (marzo 2025)', '2025-03-07', 145000.00, 1, 7),

      (@idCons_Test2, 'Renovación total del sistema eléctrico del edificio', '2025-07-06', 230000.00, 2, 5),
      (@idCons_Test3, 'Instalación de sistema contra incendios',             '2025-04-22', 100000.00, 1, 2),
      (@idCons_Test4, 'Impermeabilización y refacción de techo',             '2025-12-30', 500000.00, 1, 1);

    /* 1) Asegurar consorcios (si los Ids no existen aún)
          (en la práctica no debería dispararse porque arriba ya se crean por nombre)
    */
    IF EXISTS (SELECT 1 FROM #GastosTemp gt
               LEFT JOIN app.Tbl_Consorcio c ON c.idConsorcio = gt.idConsorcio
               WHERE c.idConsorcio IS NULL)
    BEGIN
        SET IDENTITY_INSERT app.Tbl_Consorcio ON;
        INSERT INTO app.Tbl_Consorcio (idConsorcio, nombre)
        SELECT DISTINCT gt.idConsorcio, CONCAT('Consorcio ', gt.idConsorcio)
        FROM #GastosTemp gt
        LEFT JOIN app.Tbl_Consorcio c ON c.idConsorcio = gt.idConsorcio
        WHERE c.idConsorcio IS NULL;
        SET IDENTITY_INSERT app.Tbl_Consorcio OFF;
    END

    /* 2) Expensas por (Consorcio, fechaEmision) */
    IF OBJECT_ID('tempdb..#Exp') IS NOT NULL DROP TABLE #Exp;
    CREATE TABLE #Exp (
        idConsorcio INT PRIMARY KEY,
        fecha       DATE,
        nroExpensa  INT
    );

    -- Crear las que falten (usa fechaEmision como fechaGeneracion;
    -- en nuestro caso para marzo 2025 coincide con la esperada 2025-03-07)
    INSERT INTO app.Tbl_Expensa (idConsorcio, fechaGeneracion, fechaVto1, fechaVto2, montoTotal)
    SELECT DISTINCT gt.idConsorcio, gt.fechaEmision, NULL, NULL, 0
    FROM #GastosTemp gt
    WHERE NOT EXISTS (
        SELECT 1 FROM app.Tbl_Expensa e
        WHERE e.idConsorcio     = gt.idConsorcio
          AND e.fechaGeneracion = gt.fechaEmision
    );

    -- Cargar mapeo a temp
    INSERT INTO #Exp(idConsorcio, fecha, nroExpensa)
    SELECT e.idConsorcio, e.fechaGeneracion, e.nroExpensa
    FROM app.Tbl_Expensa e
    JOIN (SELECT DISTINCT idConsorcio, fechaEmision FROM #GastosTemp) d
      ON d.idConsorcio = e.idConsorcio AND d.fechaEmision = e.fechaGeneracion;

    /* 3) Insertar GASTO Extraordinario evitando duplicados */
    INSERT INTO app.Tbl_Gasto (nroExpensa, idConsorcio, tipo, descripcion, fechaEmision, importe)
    SELECT x.nroExpensa, gt.idConsorcio, 'Extraordinario', gt.descripcion, gt.fechaEmision, gt.importe
    FROM #GastosTemp gt
    JOIN #Exp x ON x.idConsorcio = gt.idConsorcio AND x.fecha = gt.fechaEmision
    WHERE NOT EXISTS (
        SELECT 1
        FROM app.Tbl_Gasto g
        WHERE g.idConsorcio = gt.idConsorcio
          AND g.nroExpensa  = x.nroExpensa
          AND g.tipo        = 'Extraordinario'
          AND ISNULL(g.descripcion,'') = ISNULL(gt.descripcion,'')
    );

    /* 4) Detalle Extraordinario: solo si falta para esos gastos */
    INSERT INTO app.Tbl_Gasto_Extraordinario (idGasto, cuotaActual, cantCuotas)
    SELECT g.idGasto, gt.cuotaActual, gt.cantCuotas
    FROM #GastosTemp gt
    JOIN #Exp x ON x.idConsorcio = gt.idConsorcio AND x.fecha = gt.fechaEmision
    JOIN app.Tbl_Gasto g
      ON g.idConsorcio = gt.idConsorcio
     AND g.nroExpensa  = x.nroExpensa
     AND g.tipo        = 'Extraordinario'
     AND ISNULL(g.descripcion,'') = ISNULL(gt.descripcion,'')
    WHERE NOT EXISTS (
        SELECT 1 FROM app.Tbl_Gasto_Extraordinario ge WHERE ge.idGasto = g.idGasto
    );

    /* 5) Recalcular montos de las expensas afectadas */
    UPDATE e
       SET e.montoTotal = (
            SELECT ISNULL(SUM(g.importe),0)
            FROM app.Tbl_Gasto g
            WHERE g.idConsorcio = e.idConsorcio
              AND g.nroExpensa  = e.nroExpensa
       )
    FROM app.Tbl_Expensa e
    JOIN #Exp x ON x.idConsorcio = e.idConsorcio AND x.nroExpensa = e.nroExpensa;

    IF @Verbose = 1
    BEGIN
        PRINT 'Resumen de gastos extraordinarios:';
        SELECT g.idConsorcio, g.nroExpensa, g.descripcion, g.importe, ge.cuotaActual, ge.cantCuotas
        FROM app.Tbl_Gasto g
        JOIN app.Tbl_Gasto_Extraordinario ge ON ge.idGasto = g.idGasto
        WHERE g.tipo = 'Extraordinario'
        ORDER BY g.idConsorcio, g.nroExpensa, g.idGasto;
    END
END
GO
-- //////////////////////////////////////////////////////////////////////
CREATE OR ALTER PROCEDURE app.Sp_GenerarEstadoCuentaDesdeExpensas
    @Anio    INT,
    @LogPath NVARCHAR(4000) = NULL,
    @Verbose BIT = 1
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @Procedimiento SYSNAME = N'app.Sp_GenerarEstadoCuentaDesdeExpensas';

    BEGIN TRY
        IF @Verbose = 1
            EXEC reportes.Sp_LogReporte
                 @Procedimiento, 'INFO',
                 N'Inicio generación EstadosCuenta', NULL, NULL, @LogPath;

        /* 1) Expensas del año indicado */
        IF OBJECT_ID('tempdb..#exp_anio') IS NOT NULL DROP TABLE #exp_anio;

        SELECT
            e.idConsorcio,
            e.nroExpensa,
            e.fechaGeneracion
        INTO #exp_anio
        FROM app.Tbl_Expensa e
        WHERE YEAR(e.fechaGeneracion) = @Anio;

        DECLARE @ExpensasAnio INT = (SELECT COUNT(*) FROM #exp_anio);

        IF @Verbose = 1
        BEGIN
            DECLARE @DetExp NVARCHAR(4000) =
                N'expensas_anio=' + CONVERT(NVARCHAR(20), @ExpensasAnio);
            EXEC reportes.Sp_LogReporte
                 @Procedimiento, 'INFO',
                 N'Expensas a procesar', @DetExp, NULL, @LogPath;
        END

        /* 2) Crear EstadosCuenta para cada UF de cada expensa (evitando duplicados) */
        INSERT INTO app.Tbl_EstadoCuenta (nroUnidadFuncional, idConsorcio, nroExpensa)
        SELECT
            uf.idUnidadFuncional         AS nroUnidadFuncional,
            ea.idConsorcio,
            ea.nroExpensa
        FROM #exp_anio ea
        JOIN app.Tbl_UnidadFuncional uf
          ON uf.idConsorcio = ea.idConsorcio
        WHERE NOT EXISTS (
            SELECT 1
            FROM app.Tbl_EstadoCuenta ec
            WHERE ec.nroUnidadFuncional = uf.idUnidadFuncional
              AND ec.idConsorcio       = ea.idConsorcio
              AND ec.nroExpensa        = ea.nroExpensa
        );

        DECLARE @EstadosCreados INT = @@ROWCOUNT;

        IF @Verbose = 1
        BEGIN
            DECLARE @DetEC NVARCHAR(4000) =
                N'estados_creados=' + CONVERT(NVARCHAR(20), @EstadosCreados);
            EXEC reportes.Sp_LogReporte
                 @Procedimiento, 'INFO',
                 N'EstadosCuenta generados', @DetEC, NULL, @LogPath;
        END

        /* 3) Fin + resumen */
        DECLARE @Resumen NVARCHAR(4000) =
            N'expensas_anio=' + CONVERT(NVARCHAR(20), @ExpensasAnio) +
            N'; estados_creados=' + CONVERT(NVARCHAR(20), @EstadosCreados);

        IF @Verbose = 1
            EXEC reportes.Sp_LogReporte
                 @Procedimiento, 'INFO',
                 N'Fin OK', @Resumen, NULL, @LogPath;

        SELECT
            expensas_anio     = @ExpensasAnio,
            estados_creados   = @EstadosCreados,
            mensaje           = N'OK';
    END TRY
    BEGIN CATCH
        DECLARE @MsgError NVARCHAR(4000) = ERROR_MESSAGE();
        DECLARE @DetErr  NVARCHAR(4000) =
            N'Error en línea ' + CONVERT(NVARCHAR(10), ERROR_LINE());

        EXEC reportes.Sp_LogReporte
            @Procedimiento = @Procedimiento,
            @Tipo          = 'ERROR',
            @Mensaje       = @DetErr,
            @Detalle       = @MsgError,
            @RutaArchivo   = NULL,
            @RutaLog       = @LogPath;

        THROW;
    END CATCH
END
GO
-- //////////////////////////////////////////////////////////////////////
CREATE OR ALTER PROCEDURE app.Sp_RecalcularMoraEstadosCuenta_Todo
AS
BEGIN
    SET NOCOUNT ON;

    ;WITH agg_pagos AS (
        SELECT
            p.idEstadoCuenta,
            SUM(p.monto) AS montoPagado,
            MAX(p.fecha) AS fechaUltimoPago
        FROM app.Tbl_Pago p
        WHERE p.idEstadoCuenta IS NOT NULL
        GROUP BY p.idEstadoCuenta
    )
    UPDATE ec
       SET
           ec.pagoRecibido = ISNULL(ap.montoPagado, 0),

           ec.deuda =
               CASE
                   WHEN calc.baseMes <= ISNULL(ap.montoPagado, 0) THEN 0
                   ELSE calc.baseMes - ISNULL(ap.montoPagado, 0)
               END,

           ec.interesMora =
               CASE
                   WHEN calc.baseMes <= ISNULL(ap.montoPagado, 0)
                        OR ap.montoPagado IS NULL THEN 0
                   WHEN ap.fechaUltimoPago <= ex.fechaVto1 THEN 0
                   WHEN ap.fechaUltimoPago > ex.fechaVto1
                        AND (ex.fechaVto2 IS NULL OR ap.fechaUltimoPago <= ex.fechaVto2)
                        THEN ROUND(0.02 * (calc.baseMes - ISNULL(ap.montoPagado, 0)), 2)
                   WHEN ex.fechaVto2 IS NOT NULL AND ap.fechaUltimoPago > ex.fechaVto2
                        THEN ROUND(0.05 * (calc.baseMes - ISNULL(ap.montoPagado, 0)), 2)
                   ELSE 0
               END,

           ec.totalAPagar =
               CASE
                   WHEN calc.baseMes <= ISNULL(ap.montoPagado, 0) THEN 0
                   ELSE
                       (calc.baseMes - ISNULL(ap.montoPagado, 0))
                       +
                       CASE
                           WHEN ap.fechaUltimoPago <= ex.fechaVto1 THEN 0
                           WHEN ap.fechaUltimoPago > ex.fechaVto1
                                AND (ex.fechaVto2 IS NULL OR ap.fechaUltimoPago <= ex.fechaVto2)
                                THEN ROUND(0.02 * (calc.baseMes - ISNULL(ap.montoPagado, 0)), 2)
                           WHEN ex.fechaVto2 IS NOT NULL AND ap.fechaUltimoPago > ex.fechaVto2
                                THEN ROUND(0.05 * (calc.baseMes - ISNULL(ap.montoPagado, 0)), 2)
                           ELSE 0
                       END
               END
    FROM app.Tbl_EstadoCuenta ec
    LEFT JOIN agg_pagos ap
      ON ap.idEstadoCuenta = ec.idEstadoCuenta
    JOIN app.Tbl_Expensa ex
      ON ex.idConsorcio = ec.idConsorcio
     AND ex.nroExpensa  = ec.nroExpensa
    CROSS APPLY (
        SELECT baseMes =
            ISNULL(ec.expensasOrdinarias, 0) +
            ISNULL(ec.expensasExtraordinarias, 0)
    ) AS calc;
END;
GO
-- //////////////////////////////////////////////////////////////////////
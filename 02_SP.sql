USE master
GO

EXEC sys.sp_configure 'show advanced options', 1;
RECONFIGURE;
EXEC sys.sp_configure 'Ad Hoc Distributed Queries', 1;
RECONFIGURE;

EXEC dbo.sp_MSset_oledb_prop N'Microsoft.ACE.OLEDB.16.0', N'AllowInProcess', 1;
EXEC dbo.sp_MSset_oledb_prop N'Microsoft.ACE.OLEDB.16.0', N'DynamicParameters', 1;

USE Com5600G13;

IF OBJECT_ID(N'importacion.Sp_CargarConsorciosDesdeExcel', N'P') IS NOT NULL
    DROP PROCEDURE importacion.Sp_CargarConsorciosDesdeExcel;
GO

CREATE PROCEDURE importacion.Sp_CargarConsorciosDesdeExcel
    @RutaArchivo  NVARCHAR(4000),
    @Hoja         NVARCHAR(128) = N'consorcios$',
    @HDR          BIT = 1
AS
BEGIN
    SET NOCOUNT ON;

    IF EXISTS (SELECT 1 FROM app.Tbl_Consorcio)
    BEGIN
        SELECT 
            total_excel      = 0,
            procesadas_stg   = 0,
            insertadas_final = 0,
            mensaje          = N'OMITIDO: ya existen registros en app.Tbl_Consorcio';
        RETURN;
    END;

    BEGIN TRY
        -- Normalizar nombre de hoja
        DECLARE @Sheet NVARCHAR(128) = REPLACE(@Hoja, N']', N']]');
        IF RIGHT(@Sheet, 1) <> N'$' SET @Sheet = @Sheet + N'$';

        DECLARE @HdrText NVARCHAR(3) = CASE WHEN @HDR = 1 THEN N'YES' ELSE N'NO' END;

        -- Tabla RAW solo con las columnas que vamos a usar
        IF OBJECT_ID('tempdb..#RawXls') IS NOT NULL DROP TABLE #RawXls;
        CREATE TABLE #RawXls
        (
            [Nombre del consorcio] NVARCHAR(255) COLLATE DATABASE_DEFAULT NULL,
            [Domicilio]            NVARCHAR(255) COLLATE DATABASE_DEFAULT NULL,
            [m2 totales]           NVARCHAR(50)  COLLATE DATABASE_DEFAULT NULL
        );

        /* --------- OPENROWSET (seguro) --------- */
        DECLARE @prov NVARCHAR(4000) =
            N'Excel 12.0 Xml;HDR=' + @HdrText + N';IMEX=1;Database=' + REPLACE(@RutaArchivo, N'''', N'''''');

        DECLARE @qry  NVARCHAR(4000) =
            N'SELECT [Nombre del consorcio], [Domicilio], [m2 totales] FROM ' + QUOTENAME(@Sheet, N'[');

        DECLARE @sql NVARCHAR(MAX) = N'
SELECT [Nombre del consorcio], [Domicilio], [m2 totales]
FROM OPENROWSET(
    ''Microsoft.ACE.OLEDB.16.0'',
    ' + QUOTENAME(@prov,'''') + ',
    ' + QUOTENAME(@qry,'''') + '
);';

        INSERT INTO #RawXls([Nombre del consorcio],[Domicilio],[m2 totales])
        EXEC sys.sp_executesql @sql;

        -- Staging tipado
        IF OBJECT_ID('tempdb..#StgConsorcio') IS NOT NULL DROP TABLE #StgConsorcio;
        CREATE TABLE #StgConsorcio
        (
            nombre          VARCHAR(50)   COLLATE DATABASE_DEFAULT NOT NULL,
            direccion       VARCHAR(100)  COLLATE DATABASE_DEFAULT NULL,
            superficieTotal DECIMAL(10,2) NULL
        );

        INSERT INTO #StgConsorcio (nombre, direccion, superficieTotal)
        SELECT
            nombre   = LEFT(LTRIM(RTRIM(CONVERT(VARCHAR(50),  [Nombre del consorcio]))), 50),
            direccion= LEFT(LTRIM(RTRIM(CONVERT(VARCHAR(100), [Domicilio]))), 100),
            superficieTotal =
                TRY_CONVERT(DECIMAL(10,2),
                    REPLACE(NULLIF(LTRIM(RTRIM([m2 totales])), N''), N',', N'.')
                )
        FROM #RawXls
        WHERE NULLIF(LTRIM(RTRIM([Nombre del consorcio])), N'') IS NOT NULL;

        -- Insertar evitando duplicados por (nombre, direccion)
        INSERT INTO app.Tbl_Consorcio (nombre, direccion, superficieTotal)
        SELECT s.nombre, s.direccion, s.superficieTotal
        FROM #StgConsorcio s
        WHERE NOT EXISTS (
            SELECT 1
            FROM app.Tbl_Consorcio c
            WHERE c.nombre COLLATE DATABASE_DEFAULT = s.nombre
              AND ISNULL(c.direccion, '') COLLATE DATABASE_DEFAULT = ISNULL(s.direccion, '')
        );

        SELECT
            total_excel      = (SELECT COUNT(*) FROM #RawXls),
            procesadas_stg   = (SELECT COUNT(*) FROM #StgConsorcio),
            insertadas_final = @@ROWCOUNT,
            mensaje          = N'OK: carga ejecutada';
    END TRY
    BEGIN CATCH
        DECLARE @ErrMsg NVARCHAR(4000) = ERROR_MESSAGE();
        RAISERROR(@ErrMsg, 16, 1);
    END CATCH
END;
GO

IF NOT EXISTS (SELECT 1 FROM app.Tbl_Consorcio)
BEGIN
    EXEC importacion.Sp_CargarConsorciosDesdeExcel
        @RutaArchivo = N'C:\Users\PC\Desktop\consorcios\datos varios.xlsx',
        @Hoja        = N'consorcios$',
        @HDR         = 1;
END
ELSE
BEGIN
    SELECT mensaje = N'OMITIDO: ya existen registros en app.Tbl_Consorcio';
END

IF OBJECT_ID(N'importacion.Sp_CargarGastosDesdeExcel', N'P') IS NOT NULL
    DROP PROCEDURE importacion.Sp_CargarGastosDesdeExcel;
GO

CREATE PROCEDURE importacion.Sp_CargarGastosDesdeExcel
    @RutaArchivo      NVARCHAR(4000),                 -- ej: N'C:\sqlArchivos\datos varios.xlsx'
    @Hoja             NVARCHAR(128) = N'Proveedores$',-- hoja Excel
    @UsarFechaExpensa DATE = '19000101'               -- expensa destino por consorcio
AS
BEGIN
    SET NOCOUNT ON;

    BEGIN TRY
        /* === Normalizar hoja === */
        DECLARE @Sheet NVARCHAR(128) = @Hoja;
        IF RIGHT(ISNULL(@Sheet,N''),1) <> N'$' SET @Sheet = @Sheet + N'$';

        /* =================== 1) RAW: rango B3:E (HDR=NO) =================== */
        IF OBJECT_ID('tempdb..#Raw') IS NOT NULL DROP TABLE #Raw;
        CREATE TABLE #Raw (
            tipo_raw        NVARCHAR(255) COLLATE DATABASE_DEFAULT NULL,  -- B: categoría (puede ser NULL)
            descripcion_raw NVARCHAR(255) COLLATE DATABASE_DEFAULT NULL,  -- C: descripción (puede ser NULL)
            proveedor_raw   NVARCHAR(255) COLLATE DATABASE_DEFAULT NULL,  -- D: proveedor/cuenta (puede ser NULL)
            consorcio_raw   NVARCHAR(255) COLLATE DATABASE_DEFAULT NULL   -- E: consorcio (REQUIRED)
        );

        DECLARE @prov NVARCHAR(4000) =
            N'Excel 8.0;HDR=NO;Database=' + REPLACE(@RutaArchivo, N'''', N'''''');
        DECLARE @qry  NVARCHAR(4000) =
            N'SELECT F1, F2, F3, F4 FROM ' + QUOTENAME(@Sheet + N'B3:E1048576', N'[');

        DECLARE @sql NVARCHAR(MAX) = N'
SELECT
    tipo_raw        = TRY_CAST(F1 AS NVARCHAR(255)),
    descripcion_raw = TRY_CAST(F2 AS NVARCHAR(255)),
    proveedor_raw   = TRY_CAST(F3 AS NVARCHAR(255)),
    consorcio_raw   = TRY_CAST(F4 AS NVARCHAR(255))
FROM OPENROWSET(
    ''Microsoft.ACE.OLEDB.16.0'',
    ' + QUOTENAME(@prov,'''') + ',
    ' + QUOTENAME(@qry,'''') + '
);';

        INSERT INTO #Raw
        EXEC sys.sp_executesql @sql;

        /* ========== 2) STAGING tipado (permitir NULL en categoria/proveedor/descripcion) ========== */
        IF OBJECT_ID('tempdb..#Stg') IS NOT NULL DROP TABLE #Stg;
        CREATE TABLE #Stg
        (
            stgId       INT IDENTITY(1,1) PRIMARY KEY,
            idConsorcio INT            NOT NULL,
            categoria   VARCHAR(35)    COLLATE DATABASE_DEFAULT NULL,
            descripcion VARCHAR(200)   COLLATE DATABASE_DEFAULT NULL,
            proveedor   VARCHAR(100)   COLLATE DATABASE_DEFAULT NULL
        );

        INSERT INTO #Stg (idConsorcio, categoria, descripcion, proveedor)
        SELECT
            c.idConsorcio,
            /* categoría/proveedor/descripcion pueden quedar NULL si vienen vacíos */
            NULLIF(LEFT(LTRIM(RTRIM(CONVERT(VARCHAR(35),  r.tipo_raw))), 35), ''),
            NULLIF(LEFT(LTRIM(RTRIM(CONVERT(VARCHAR(200), r.descripcion_raw))), 200), ''),
            NULLIF(LEFT(LTRIM(RTRIM(CONVERT(VARCHAR(100), r.proveedor_raw))), 100), '')
        FROM #Raw r
        JOIN app.Tbl_Consorcio c
          ON c.nombre COLLATE DATABASE_DEFAULT =
             LTRIM(RTRIM(CONVERT(VARCHAR(50), r.consorcio_raw))) COLLATE DATABASE_DEFAULT
        /* ⚠️ ÚNICO requisito: que exista consorcio */
        WHERE NULLIF(LTRIM(RTRIM(r.consorcio_raw)), N'') IS NOT NULL;

        /* ===== 3) Expensa destino por consorcio (@UsarFechaExpensa) ===== */
        IF OBJECT_ID('tempdb..#ExpDst') IS NOT NULL DROP TABLE #ExpDst;
        CREATE TABLE #ExpDst (idConsorcio INT PRIMARY KEY, nroExpensa INT NOT NULL);

        ;WITH DistCons AS (SELECT DISTINCT idConsorcio FROM #Stg)
        INSERT INTO #ExpDst (idConsorcio, nroExpensa)
        SELECT d.idConsorcio,
               e.nroExpensa
        FROM DistCons d
        OUTER APPLY (
            SELECT TOP(1) e.nroExpensa
            FROM app.Tbl_Expensa e
            WHERE e.idConsorcio = d.idConsorcio
              AND e.fechaGeneracion = @UsarFechaExpensa
            ORDER BY e.nroExpensa
        ) e
        WHERE e.nroExpensa IS NOT NULL;

        DECLARE @insExp TABLE (nroExpensa INT, idConsorcio INT);
        INSERT INTO app.Tbl_Expensa (idConsorcio, fechaGeneracion, fechaVto1, fechaVto2, montoTotal)
        OUTPUT inserted.nroExpensa, inserted.idConsorcio INTO @insExp(nroExpensa, idConsorcio)
        SELECT d.idConsorcio, @UsarFechaExpensa, NULL, NULL, 0
        FROM (SELECT DISTINCT idConsorcio FROM #Stg) d
        WHERE NOT EXISTS (SELECT 1 FROM #ExpDst x WHERE x.idConsorcio = d.idConsorcio);

        INSERT INTO #ExpDst (idConsorcio, nroExpensa)
        SELECT i.idConsorcio, i.nroExpensa FROM @insExp i;

        /* ===== 4) MERGE + OUTPUT (duplicados NULL-safe) ===== */
        IF OBJECT_ID('tempdb..#Map') IS NOT NULL DROP TABLE #Map;
        CREATE TABLE #Map (idGasto INT NOT NULL, stgId INT NOT NULL);

        MERGE app.Tbl_Gasto AS tgt
        USING (
            SELECT
                s.stgId,
                x.nroExpensa,
                s.idConsorcio,
                s.descripcion,
                CONVERT(date, GETDATE()) AS fechaEmision,
                CAST(0 AS DECIMAL(10,2)) AS importe,
                s.categoria,
                s.proveedor
            FROM #Stg s
            JOIN #ExpDst x ON x.idConsorcio = s.idConsorcio
        ) AS src
        ON 1 = 0
        WHEN NOT MATCHED BY TARGET
             AND NOT EXISTS (
                 SELECT 1
                 FROM app.Tbl_Gasto g
                 LEFT JOIN app.Tbl_Gasto_Ordinario go2 ON go2.idGasto = g.idGasto
                 WHERE g.idConsorcio = src.idConsorcio
                   AND g.nroExpensa  = src.nroExpensa
                   AND ISNULL(go2.nombreProveedor,'') COLLATE DATABASE_DEFAULT = ISNULL(src.proveedor,'')
                   AND ISNULL(go2.categoria,'')       COLLATE DATABASE_DEFAULT = ISNULL(src.categoria,'')
                   AND ISNULL(g.descripcion,'')        COLLATE DATABASE_DEFAULT = ISNULL(src.descripcion,'')
             )
        THEN INSERT (nroExpensa, idConsorcio, tipo,      descripcion,     fechaEmision,      importe)
             VALUES (src.nroExpensa, src.idConsorcio, 'Ordinario', src.descripcion, src.fechaEmision, src.importe)
        OUTPUT inserted.idGasto, src.stgId INTO #Map(idGasto, stgId);

        /* Detalle ordinario (permite NULL en proveedor/categoria/nroFactura) */
        INSERT INTO app.Tbl_Gasto_Ordinario (idGasto, nombreProveedor, categoria, nroFactura)
        SELECT m.idGasto, s.proveedor, s.categoria, NULL
        FROM #Map m
        JOIN #Stg s ON s.stgId = m.stgId;

        /* ===== 5) Resultado ===== */
        SELECT
            filas_excel    = (SELECT COUNT(*) FROM #Raw),
            filas_validas  = (SELECT COUNT(*) FROM #Stg),
            gastos_insert  = (SELECT COUNT(*) FROM #Map),
            msg            = N'OK: insertó también filas sin categoría/proveedor (expensa ' +
                             CONVERT(VARCHAR(10), @UsarFechaExpensa, 120) + N')';
    END TRY
    BEGIN CATCH
        DECLARE @Err NVARCHAR(4000) = ERROR_MESSAGE();
        RAISERROR(@Err, 16, 1);
    END CATCH
END;
GO

EXEC importacion.Sp_CargarGastosDesdeExcel
    @RutaArchivo      = N'C:\Users\PC\Desktop\consorcios\datos varios.xlsx',
    @Hoja             = N'Proveedores$',
    @UsarFechaExpensa = '19000101';

-- SELECT * FROM app.Tbl_Consorcio;

-- SELECT * FROM app.Tbl_Gasto;

-- SELECT * FROM app.Tbl_Gasto_Ordinario;

IF OBJECT_ID(N'importacion.Sp_CargarConsorcioYUF_DesdeCsv', N'P') IS NOT NULL
    DROP PROCEDURE importacion.Sp_CargarConsorcioYUF_DesdeCsv;
GO

CREATE PROCEDURE importacion.Sp_CargarConsorcioYUF_DesdeCsv
    @RutaArchivo    NVARCHAR(4000),           -- ej: N'C:\...\Inquilino-propietarios-UF.csv'
    @HDR            BIT = 1,                  -- 1 = primera fila encabezado
    @SoloPreview    BIT = 0                   -- 1 = solo mostrar, 0 = insertar
AS
BEGIN
    SET NOCOUNT ON;

    BEGIN TRY
        /* 1) RAW: columnas EXACTAS del CSV (UTF-8 BOM, CRLF, '|') */
        IF OBJECT_ID('tempdb..#RawUF','U') IS NOT NULL DROP TABLE #RawUF;
        CREATE TABLE #RawUF
        (
            [CVU/CBU]              NVARCHAR(255) COLLATE Latin1_General_CI_AI NULL,
            [Nombre del consorcio] NVARCHAR(255) COLLATE Latin1_General_CI_AI NULL,
            [nroUnidadFuncional]   NVARCHAR(50)  COLLATE Latin1_General_CI_AI NULL,
            [piso]                 NVARCHAR(50)  COLLATE Latin1_General_CI_AI NULL,
            [departamento]         NVARCHAR(50)  COLLATE Latin1_General_CI_AI NULL
        );

        DECLARE @FirstRow INT = CASE WHEN @HDR=1 THEN 2 ELSE 1 END;

        DECLARE @sql NVARCHAR(MAX) = N'
BULK INSERT #RawUF
FROM ' + QUOTENAME(@RutaArchivo,'''') + N'
WITH (
    FIRSTROW = ' + CAST(@FirstRow AS NVARCHAR(10)) + N',
    FIELDTERMINATOR = ''|'',
    ROWTERMINATOR   = ''0x0d0a'',    -- CRLF (si no levanta, probar 0x0a)
    CODEPAGE        = ''65001'',     -- UTF-8 (BOM ok)
    KEEPNULLS,
    TABLOCK
);';
        EXEC (@sql);

        /* 2) STAGING tipado (PB => 0) */
        IF OBJECT_ID('tempdb..#Stg','U') IS NOT NULL DROP TABLE #Stg;
        CREATE TABLE #Stg
        (
            idUnidadFuncional INT         NOT NULL,
            nombre            VARCHAR(50) COLLATE Latin1_General_CI_AI NOT NULL,
            piso              TINYINT     NULL,
            departamento      CHAR(1)     COLLATE Latin1_General_CI_AI NULL
        );

        INSERT INTO #Stg (idUnidadFuncional, nombre, piso, departamento)
        SELECT
            idUnidadFuncional = TRY_CONVERT(INT, NULLIF(LTRIM(RTRIM([nroUnidadFuncional])), '')),
            nombre            = LEFT(LTRIM(RTRIM(CONVERT(VARCHAR(50), [Nombre del consorcio]))), 50),
            piso = CASE
                      WHEN UPPER(LTRIM(RTRIM([piso]))) IN (N'PB', N'P.B', N'P.B.', N'PLANTA BAJA') THEN 0
                      ELSE TRY_CONVERT(TINYINT, NULLIF(LTRIM(RTRIM([piso])), ''))
                   END,
            departamento      = CASE
                                   WHEN NULLIF(LTRIM(RTRIM([departamento])), '') IS NULL THEN NULL
                                   ELSE SUBSTRING(LTRIM(RTRIM([departamento])),1,1)
                                END
        FROM #RawUF
        WHERE NULLIF(LTRIM(RTRIM([Nombre del consorcio])), '') IS NOT NULL
          AND TRY_CONVERT(INT, NULLIF(LTRIM(RTRIM([nroUnidadFuncional])), '')) IS NOT NULL;

        -- Duplicados en CSV (para métricas)
        ;WITH d AS (
          SELECT idUnidadFuncional, COUNT(*) AS cnt
          FROM #Stg
          GROUP BY idUnidadFuncional
        )
        SELECT SUM(CASE WHEN cnt>1 THEN cnt-1 ELSE 0 END) AS dups_en_csv
        INTO #CsvDupCount
        FROM d;

        -- 2.b) DEDUP para evitar errores en UPDATE/INSERT (1 fila por id)
        ;WITH ranked AS (
          SELECT *,
                 ROW_NUMBER() OVER(
                    PARTITION BY idUnidadFuncional
                    ORDER BY
                      CASE WHEN piso IS NOT NULL THEN 0 ELSE 1 END,
                      CASE WHEN departamento IS NOT NULL THEN 0 ELSE 1 END,
                      nombre
                 ) AS rn
          FROM #Stg
        )
        SELECT idUnidadFuncional, nombre, piso, departamento
        INTO #StgDedup
        FROM ranked
        WHERE rn = 1;

        IF (@SoloPreview = 1)
        BEGIN
            SELECT
                filas_csv     = (SELECT COUNT(*) FROM #RawUF),
                filas_tipadas = (SELECT COUNT(*) FROM #Stg),
                filas_dedup   = (SELECT COUNT(*) FROM #StgDedup),
                dups_en_csv   = (SELECT dups_en_csv FROM #CsvDupCount),
                msg = N'Preview listo. Si ves 0 filas, revisá ruta/permisos o terminador (0x0a vs 0x0d0a).';
            RETURN;
        END

        /* 3) CONSORCIOS por nombre (sin dirección/superficie) */
        DECLARE @insCons TABLE (idConsorcio INT);
        INSERT INTO app.Tbl_Consorcio (nombre, direccion, superficieTotal)
        OUTPUT inserted.idConsorcio INTO @insCons(idConsorcio)
        SELECT s.nombre, NULL, NULL
        FROM (SELECT DISTINCT nombre FROM #StgDedup) s
        WHERE NOT EXISTS (
            SELECT 1
            FROM app.Tbl_Consorcio c
            WHERE c.nombre COLLATE Latin1_General_CI_AI = s.nombre COLLATE Latin1_General_CI_AI
        );

        /* 4a) UPDATE de UFs existentes (aplicar TODO lo del CSV) */
        UPDATE u
           SET u.idConsorcio  = c.idConsorcio,
               u.piso         = s.piso,
               u.departamento = s.departamento
        FROM app.Tbl_UnidadFuncional u
        JOIN #StgDedup s
          ON s.idUnidadFuncional = u.idUnidadFuncional
        JOIN app.Tbl_Consorcio c
          ON c.nombre COLLATE Latin1_General_CI_AI = s.nombre COLLATE Latin1_General_CI_AI;

        DECLARE @rowsUpd INT = @@ROWCOUNT;

        /* 4b) INSERT de UFs nuevas (respetando id del archivo) */
        SET IDENTITY_INSERT app.Tbl_UnidadFuncional ON;

        INSERT INTO app.Tbl_UnidadFuncional
            (idUnidadFuncional, idConsorcio, piso, departamento, superficie, metrosBaulera, metrosCochera, porcentaje)
        SELECT
            s.idUnidadFuncional,
            c.idConsorcio,
            s.piso,
            s.departamento,
            NULL, NULL, NULL, NULL
        FROM #StgDedup s
        JOIN app.Tbl_Consorcio c
          ON c.nombre COLLATE Latin1_General_CI_AI = s.nombre COLLATE Latin1_General_CI_AI
        WHERE NOT EXISTS (
            SELECT 1 FROM app.Tbl_UnidadFuncional u WHERE u.idUnidadFuncional = s.idUnidadFuncional
        );

        DECLARE @rowsIns INT = @@ROWCOUNT;

        SET IDENTITY_INSERT app.Tbl_UnidadFuncional OFF;

        -- Reseed identidad para futuros inserts automáticos
        DECLARE @maxUF INT;
        SELECT @maxUF = MAX(idUnidadFuncional) FROM app.Tbl_UnidadFuncional;
        IF @maxUF IS NOT NULL
            DBCC CHECKIDENT ('app.Tbl_UnidadFuncional', RESEED, @maxUF) WITH NO_INFOMSGS;

        /* 5) Resultado */
        SELECT
            filas_csv            = (SELECT COUNT(*) FROM #RawUF),
            filas_tipadas        = (SELECT COUNT(*) FROM #Stg),
            filas_dedup          = (SELECT COUNT(*) FROM #StgDedup),
            dups_en_csv          = (SELECT dups_en_csv FROM #CsvDupCount),
            consorcios_nuevos    = (SELECT COUNT(*) FROM @insCons),
            ufs_actualizadas     = @rowsUpd,
            ufs_insertadas       = @rowsIns,
            mensaje              = N'OK: se aplicó todo (UPDATE existentes + INSERT nuevas). PB => piso 0';
    END TRY
    BEGIN CATCH
        DECLARE @Err NVARCHAR(4000) = ERROR_MESSAGE();
        RAISERROR(@Err, 16, 1);
    END CATCH
END;
GO

EXEC importacion.Sp_CargarConsorcioYUF_DesdeCsv
    @RutaArchivo = N'C:\Users\PC\Desktop\consorcios\Inquilino-propietarios-UF.csv',
    @HDR = 1,
    @SoloPreview = 0;  -- inserta/actualiza

-- SELECT * FROM app.Tbl_UnidadFuncional;

IF OBJECT_ID(N'importacion.Sp_CargarUFsDesdeTxt', N'P') IS NOT NULL
    DROP PROCEDURE importacion.Sp_CargarUFsDesdeTxt;
GO

CREATE PROCEDURE importacion.Sp_CargarUFsDesdeTxt
    @RutaArchivo    NVARCHAR(4000),            -- ej: N'C:\Temp\UF por consorcio.txt'
    @HDR            BIT = 1,                   -- 1 = primera fila es encabezado
    @RowTerminator  NVARCHAR(10) = N'0x0d0a',  -- CRLF (probar '0x0a' si sólo LF)
    @CodePage       NVARCHAR(16) = N'65001'    -- UTF-8 (probar 'ACP' si ANSI)
AS
BEGIN
    SET NOCOUNT ON;

    BEGIN TRY
        /* 1) RAW: columnas exactamente como vienen en el TXT (TAB = 0x09) */
        IF OBJECT_ID('tempdb..#RawUF','U') IS NOT NULL DROP TABLE #RawUF;
        CREATE TABLE #RawUF
        (
            [Nombre del consorcio] NVARCHAR(255) COLLATE Latin1_General_CI_AI NULL,
            [nroUnidadFuncional]   NVARCHAR(50)  COLLATE Latin1_General_CI_AI NULL,
            [Piso]                 NVARCHAR(50)  COLLATE Latin1_General_CI_AI NULL,
            [departamento]         NVARCHAR(50)  COLLATE Latin1_General_CI_AI NULL,
            [coeficiente]          NVARCHAR(50)  COLLATE Latin1_General_CI_AI NULL,
            [m2_unidad_funcional]  NVARCHAR(50)  COLLATE Latin1_General_CI_AI NULL,
            [bauleras]             NVARCHAR(10)  COLLATE Latin1_General_CI_AI NULL,
            [cochera]              NVARCHAR(10)  COLLATE Latin1_General_CI_AI NULL,
            [m2_baulera]           NVARCHAR(50)  COLLATE Latin1_General_CI_AI NULL,
            [m2_cochera]           NVARCHAR(50)  COLLATE Latin1_General_CI_AI NULL
        );

        DECLARE @FirstRow INT = CASE WHEN @HDR=1 THEN 2 ELSE 1 END;

        DECLARE @sql NVARCHAR(MAX) = N'
BULK INSERT #RawUF
FROM ' + QUOTENAME(@RutaArchivo,'''') + N'
WITH (
    FIRSTROW = ' + CAST(@FirstRow AS NVARCHAR(10)) + N',
    FIELDTERMINATOR = ''0x09'',   -- TAB
    ROWTERMINATOR   = ' + QUOTENAME(@RowTerminator,'''') + N',
    CODEPAGE        = ' + QUOTENAME(@CodePage,'''') + N',
    KEEPNULLS,
    TABLOCK
);';
        EXEC (@sql);

        /* 2) STAGING tipado + normalización (PB => 0) */
        IF OBJECT_ID('tempdb..#Stg','U') IS NOT NULL DROP TABLE #Stg;
        CREATE TABLE #Stg
        (
            nombre           VARCHAR(50)   COLLATE Latin1_General_CI_AI NOT NULL,
            piso             TINYINT       NULL,
            departamento     CHAR(1)       COLLATE Latin1_General_CI_AI NULL,
            porcentaje       DECIMAL(5,2)  NULL,
            superficie       DECIMAL(7,2)  NULL,
            metrosBaulera    DECIMAL(5,2)  NULL,
            metrosCochera    DECIMAL(5,2)  NULL
        );

        INSERT INTO #Stg (nombre, piso, departamento, porcentaje, superficie, metrosBaulera, metrosCochera)
        SELECT
            nombre       = LEFT(LTRIM(RTRIM(CONVERT(VARCHAR(50), [Nombre del consorcio]))), 50),
            piso         = CASE
                              WHEN UPPER(LTRIM(RTRIM([Piso]))) IN (N'PB', N'P.B', N'P.B.', N'PLANTA BAJA')
                                  THEN 0
                              ELSE TRY_CONVERT(TINYINT, NULLIF(LTRIM(RTRIM([Piso])), ''))
                           END,
            departamento = CASE
                              WHEN NULLIF(LTRIM(RTRIM([departamento])), '') IS NULL
                                  THEN NULL
                              ELSE SUBSTRING(LTRIM(RTRIM([departamento])),1,1)
                           END,
            porcentaje   = TRY_CONVERT(DECIMAL(5,2),  REPLACE(NULLIF(LTRIM(RTRIM([coeficiente])), ''), ',', '.')),
            superficie   = TRY_CONVERT(DECIMAL(7,2),  REPLACE(NULLIF(LTRIM(RTRIM([m2_unidad_funcional])), ''), ',', '.')),
            metrosBaulera= TRY_CONVERT(DECIMAL(5,2),  REPLACE(NULLIF(LTRIM(RTRIM([m2_baulera])), ''), ',', '.')),
            metrosCochera= TRY_CONVERT(DECIMAL(5,2),  REPLACE(NULLIF(LTRIM(RTRIM([m2_cochera])), ''), ',', '.'))
        FROM #RawUF
        WHERE NULLIF(LTRIM(RTRIM([Nombre del consorcio])), '') IS NOT NULL;

        /* 3) CONSORCIOS (crear si faltan) */
        INSERT INTO app.Tbl_Consorcio (nombre, direccion, superficieTotal)
        SELECT DISTINCT s.nombre, NULL, NULL
        FROM #Stg s
        WHERE NOT EXISTS (
            SELECT 1
            FROM app.Tbl_Consorcio c
            WHERE c.nombre COLLATE Latin1_General_CI_AI = s.nombre COLLATE Latin1_General_CI_AI
        );

        /* 4) UFs: insertar evitando duplicar por (idConsorcio, piso, departamento) */
        INSERT INTO app.Tbl_UnidadFuncional
            (idConsorcio, piso, departamento, superficie, metrosBaulera, metrosCochera, porcentaje)
        SELECT
            c.idConsorcio,
            s.piso,
            s.departamento,
            s.superficie,
            s.metrosBaulera,
            s.metrosCochera,
            s.porcentaje
        FROM #Stg s
        JOIN app.Tbl_Consorcio c
          ON c.nombre COLLATE Latin1_General_CI_AI = s.nombre COLLATE Latin1_General_CI_AI
        WHERE NOT EXISTS (
            SELECT 1
            FROM app.Tbl_UnidadFuncional u
            WHERE u.idConsorcio = c.idConsorcio
              AND ISNULL(u.piso, 255) = ISNULL(s.piso, 255)
              AND ISNULL(u.departamento,'') COLLATE Latin1_General_CI_AI
                    = ISNULL(s.departamento,'') COLLATE Latin1_General_CI_AI
        );

        /* 5) Resultado */
        SELECT
            filas_txt        = (SELECT COUNT(*) FROM #RawUF),
            filas_validas    = (SELECT COUNT(*) FROM #Stg),
            consorcios_nuevos= (SELECT COUNT(*) FROM app.Tbl_Consorcio c
                                 WHERE EXISTS (SELECT 1 FROM #Stg s
                                               WHERE s.nombre COLLATE Latin1_General_CI_AI
                                                   = c.nombre COLLATE Latin1_General_CI_AI)),
            ufs_insertadas   = @@ROWCOUNT,
            mensaje          = N'OK: cargado. PB→0, decimales con coma convertidos';
    END TRY
    BEGIN CATCH
        
    END CATCH
END;
GO

EXEC importacion.Sp_CargarUFsDesdeTxt
    @RutaArchivo   = N'C:\Users\PC\Desktop\consorcios\UF por consorcio.txt',
    @HDR           = 1,              -- 0 si NO hay encabezado
    @RowTerminator = N'0x0d0a',      -- probá N'0x0a' si no levanta
    @CodePage      = N'65001';       -- si ves acentos raros, probá N'ACP'

-- SELECT * FROM app.Tbl_Consorcio;

-- SELECT * FROM app.Tbl_UnidadFuncional;

IF OBJECT_ID(N'importacion.Sp_CargarUFPersonaDesdeTxt', N'P') IS NOT NULL
    DROP PROCEDURE importacion.Sp_CargarUFPersonaDesdeTxt;
GO

CREATE PROCEDURE importacion.Sp_CargarUFPersonaDesdeTxt
    @RutaArchivo    NVARCHAR(4000),            -- ej: N'C:\Temp\Personas-UF.txt'
    @HDR            BIT = 1,                   -- 1: primera fila encabezado
    @RowTerminator  NVARCHAR(10) = N'0x0d0a',  -- CRLF (usar '0x0a' si sólo LF)
    @CodePage       NVARCHAR(16) = N'65001'    -- UTF-8; usar 'ACP' si Latin-1
AS
BEGIN
    SET NOCOUNT ON;

    BEGIN TRY
        /* 1) RAW: columnas exactas del archivo (TAB = 0x09) */
        IF OBJECT_ID('tempdb..#Raw','U') IS NOT NULL DROP TABLE #Raw;
        CREATE TABLE #Raw
        (
            [Nombre del consorcio] NVARCHAR(255) COLLATE Latin1_General_CI_AI NULL,
            [Piso]                 NVARCHAR(50)  COLLATE Latin1_General_CI_AI NULL,
            [departamento]         NVARCHAR(50)  COLLATE Latin1_General_CI_AI NULL,
            [DNI]                  NVARCHAR(50)  COLLATE Latin1_General_CI_AI NULL,
            [esInquilino]          NVARCHAR(20)  COLLATE Latin1_General_CI_AI NULL,
            [fechaInicio]          NVARCHAR(50)  COLLATE Latin1_General_CI_AI NULL,
            [fechaFin]             NVARCHAR(50)  COLLATE Latin1_General_CI_AI NULL
        );

        DECLARE @FirstRow INT = CASE WHEN @HDR=1 THEN 2 ELSE 1 END;

        DECLARE @sql NVARCHAR(MAX) = N'
BULK INSERT #Raw
FROM ' + QUOTENAME(@RutaArchivo,'''') + N'
WITH (
    FIRSTROW = ' + CAST(@FirstRow AS NVARCHAR(10)) + N',
    FIELDTERMINATOR = ''0x09'',     -- TAB
    ROWTERMINATOR   = ' + QUOTENAME(@RowTerminator,'''') + N',
    CODEPAGE        = ' + QUOTENAME(@CodePage,'''') + N',
    KEEPNULLS,
    TABLOCK
);';
        EXEC (@sql);

        -- Preview opcional
        -- SELECT TOP (20) * FROM #Raw;

        /* 2) STAGING tipado y normalización */
        IF OBJECT_ID('tempdb..#Stg','U') IS NOT NULL DROP TABLE #Stg;
        CREATE TABLE #Stg
        (
            dni           INT          NOT NULL,
            nombreCons    VARCHAR(50)  COLLATE Latin1_General_CI_AI NOT NULL,
            piso          TINYINT      NULL,
            departamento  CHAR(1)      COLLATE Latin1_General_CI_AI NULL,
            esInquilino   BIT          NULL,
            fechaInicio   DATE         NULL,
            fechaFin      DATE         NULL
        );

        INSERT INTO #Stg (dni, nombreCons, piso, departamento, esInquilino, fechaInicio, fechaFin)
        SELECT
            dni = TRY_CONVERT(INT, NULLIF(LTRIM(RTRIM([DNI])),'')),
            nombreCons = LEFT(LTRIM(RTRIM(CONVERT(VARCHAR(50), [Nombre del consorcio]))), 50),
            piso = CASE
                     WHEN UPPER(LTRIM(RTRIM([Piso]))) IN (N'PB', N'P.B', N'P.B.', N'PLANTA BAJA') THEN 0
                     ELSE TRY_CONVERT(TINYINT, NULLIF(LTRIM(RTRIM([Piso])), ''))
                   END,
            departamento = CASE
                              WHEN NULLIF(LTRIM(RTRIM([departamento])), '') IS NULL THEN NULL
                              ELSE SUBSTRING(LTRIM(RTRIM([departamento])),1,1)
                           END,
            esInquilino = CASE
                            WHEN [esInquilino] IS NULL THEN NULL
                            WHEN UPPER(LTRIM(RTRIM([esInquilino]))) IN (N'SI',N'SÍ',N'1',N'TRUE',N'V') THEN 1
                            WHEN UPPER(LTRIM(RTRIM([esInquilino]))) IN (N'NO',N'0',N'FALSE') THEN 0
                            ELSE NULL
                          END,
            fechaInicio = TRY_CONVERT(date, NULLIF(LTRIM(RTRIM([fechaInicio])), '')),
            fechaFin    = TRY_CONVERT(date, NULLIF(LTRIM(RTRIM([fechaFin])), ''))
        FROM #Raw
        WHERE TRY_CONVERT(INT, NULLIF(LTRIM(RTRIM([DNI])),'')) IS NOT NULL
          AND NULLIF(LTRIM(RTRIM([Nombre del consorcio])),'') IS NOT NULL
          AND (NULLIF(LTRIM(RTRIM([Piso])),'') IS NOT NULL OR NULLIF(LTRIM(RTRIM([departamento])),'') IS NOT NULL);

        /* 3) Resolver claves (idPersona, idConsorcio, idUnidadFuncional) */
        IF OBJECT_ID('tempdb..#Keys','U') IS NOT NULL DROP TABLE #Keys;
        CREATE TABLE #Keys
        (
            idPersona         INT NOT NULL,
            idConsorcio       INT NOT NULL,
            idUnidadFuncional INT NOT NULL,
            esInquilino       BIT NULL,
            fechaInicio       DATE NULL,
            fechaFin          DATE NULL
        );

        INSERT INTO #Keys (idPersona, idConsorcio, idUnidadFuncional, esInquilino, fechaInicio, fechaFin)
        SELECT
            p.idPersona,
            c.idConsorcio,
            u.idUnidadFuncional,
            s.esInquilino,
            s.fechaInicio,
            s.fechaFin
        FROM #Stg s
        JOIN app.Tbl_Persona p
          ON p.dni = s.dni
        JOIN app.Tbl_Consorcio c
          ON c.nombre COLLATE Latin1_General_CI_AI = s.nombreCons COLLATE Latin1_General_CI_AI
        JOIN app.Tbl_UnidadFuncional u
          ON u.idConsorcio = c.idConsorcio
         AND ISNULL(u.piso,255) = ISNULL(s.piso,255)
         AND ISNULL(u.departamento,'') COLLATE Latin1_General_CI_AI
             = ISNULL(s.departamento,'') COLLATE Latin1_General_CI_AI;

        /* 4) UPSERT en app.Tbl_UFPersona */
        -- UPDATE si ya existe (misma persona + misma UF)
        UPDATE up
           SET up.idConsorcio = k.idConsorcio,
               up.esInquilino = COALESCE(k.esInquilino, up.esInquilino),
               up.fechaInicio = COALESCE(k.fechaInicio, up.fechaInicio),
               up.fechaFin    = COALESCE(k.fechaFin, up.fechaFin)
        FROM app.Tbl_UFPersona up
        JOIN #Keys k
          ON k.idPersona = up.idPersona
         AND k.idUnidadFuncional = up.idUnidadFuncional;

        DECLARE @upd INT = @@ROWCOUNT;

        -- INSERT si no existe
        INSERT INTO app.Tbl_UFPersona
            (idPersona, idUnidadFuncional, idConsorcio, esInquilino, fechaInicio, fechaFin)
        SELECT
            k.idPersona, k.idUnidadFuncional, k.idConsorcio, k.esInquilino, k.fechaInicio, k.fechaFin
        FROM #Keys k
        WHERE NOT EXISTS (
            SELECT 1
            FROM app.Tbl_UFPersona up
            WHERE up.idPersona = k.idPersona
              AND up.idUnidadFuncional = k.idUnidadFuncional
        );

        DECLARE @ins INT = @@ROWCOUNT;

        /* 5) Resultado */
        SELECT
            filas_archivo     = (SELECT COUNT(*) FROM #Raw),
            filas_validas     = (SELECT COUNT(*) FROM #Stg),
            filas_resueltas   = (SELECT COUNT(*) FROM #Keys),
            relaciones_upd    = @upd,
            relaciones_ins    = @ins,
            msg = N'OK: UFPersona cargada/actualizada (PB→0; admite SI/NO, 1/0, TRUE/FALSE).';
    END TRY
    BEGIN CATCH
        
    END CATCH
END;
GO

IF OBJECT_ID(N'importacion.Sp_CargarPersonasDesdeCsvDatos', N'P') IS NOT NULL
    DROP PROCEDURE importacion.Sp_CargarPersonasDesdeCsvDatos;
GO

CREATE PROCEDURE importacion.Sp_CargarPersonasDesdeCsvDatos
    @RutaArchivo    NVARCHAR(4000),            -- ej: N'C:\...\Inquilino-propietarios-datos.csv'
    @HDR            BIT = 1,                   -- 1 = primera fila encabezado
    @RowTerminator  NVARCHAR(10) = N'0x0d0a',  -- CRLF (usar '0x0a' si solo LF)
    @CodePage       NVARCHAR(16) = N'ACP'      -- Latin1/Windows-1252; usar '65001' si UTF-8
AS
BEGIN
    SET NOCOUNT ON;

    BEGIN TRY
        /* 1) RAW: columnas como vienen (separador ';') */
        IF OBJECT_ID('tempdb..#Raw','U') IS NOT NULL DROP TABLE #Raw;
        CREATE TABLE #Raw
        (
            [Nombre]                 NVARCHAR(255) COLLATE Latin1_General_CI_AI NULL,
            [apellido]               NVARCHAR(255) COLLATE Latin1_General_CI_AI NULL,
            [DNI]                    NVARCHAR(50)  COLLATE Latin1_General_CI_AI NULL,
            [email personal]         NVARCHAR(255) COLLATE Latin1_General_CI_AI NULL,
            [telfono de contacto]   NVARCHAR(255) COLLATE Latin1_General_CI_AI NULL, -- viene así
            [CVU/CBU]                NVARCHAR(64)  COLLATE Latin1_General_CI_AI NULL,
            [Inquilino]              NVARCHAR(50)  COLLATE Latin1_General_CI_AI NULL   -- ignorado
        );

        DECLARE @FirstRow INT = CASE WHEN @HDR=1 THEN 2 ELSE 1 END;

        DECLARE @sql NVARCHAR(MAX) = N'
BULK INSERT #Raw
FROM ' + QUOTENAME(@RutaArchivo,'''') + N'
WITH (
    FIRSTROW = ' + CAST(@FirstRow AS NVARCHAR(10)) + N',
    FIELDTERMINATOR = '';'',
    ROWTERMINATOR   = ' + QUOTENAME(@RowTerminator,'''') + N',
    CODEPAGE        = ' + QUOTENAME(@CodePage,'''') + N',
    KEEPNULLS,
    TABLOCK
);';
        EXEC (@sql);

        /* 2) STAGING tipado/limpio */
        IF OBJECT_ID('tempdb..#Stg','U') IS NOT NULL DROP TABLE #Stg;
        CREATE TABLE #Stg
        (
            nombre     VARCHAR(50)  COLLATE Latin1_General_CI_AI NOT NULL,
            apellido   VARCHAR(50)  COLLATE Latin1_General_CI_AI NOT NULL,
            dni        INT          NOT NULL,
            email      VARCHAR(100) COLLATE Latin1_General_CI_AI NULL,
            telefono   VARCHAR(12)  COLLATE Latin1_General_CI_AI NULL,
            cbu_cvu    CHAR(22)     COLLATE Latin1_General_CI_AI NULL
        );

        ;WITH t AS
        (
            SELECT
                nom   = LEFT(LTRIM(RTRIM(CONVERT(VARCHAR(50),  [Nombre]))), 50),
                ape   = LEFT(LTRIM(RTRIM(CONVERT(VARCHAR(50),  [apellido]))), 50),
                dni_s = LTRIM(RTRIM([DNI])),
                mail  = LOWER(LTRIM(RTRIM(CONVERT(VARCHAR(100), [email personal])))),
                tel_s = LTRIM(RTRIM([telfono de contacto])),
                cbu_s = LTRIM(RTRIM([CVU/CBU]))
            FROM #Raw
        ),
        tel AS
        (
            SELECT
                nom, ape, dni_s, mail,
                tel_clean = CASE WHEN tel_s IS NULL THEN NULL
                                 ELSE REPLACE(REPLACE(REPLACE(REPLACE(REPLACE(tel_s,' ',''),'-',''),'(',''),')',''),'.','')
                            END,
                cbu_s
            FROM t
        ),
        cbu AS
        (
            SELECT
                nom, ape, dni_s, mail, tel_clean,
                cbu_digits = CASE WHEN cbu_s IS NULL THEN NULL
                                  ELSE REPLACE(REPLACE(REPLACE(REPLACE(REPLACE(REPLACE(REPLACE(REPLACE(REPLACE(REPLACE(cbu_s
                                        ,' ',''),'-',''),'.',''),'/',''),'\',''),'_',''),'(',''),')',''),CHAR(9),''),CHAR(160),'')
                             END
            FROM tel
        )
        INSERT INTO #Stg (nombre, apellido, dni, email, telefono, cbu_cvu)
        SELECT
            nom,
            ape,
            TRY_CONVERT(INT, NULLIF(dni_s,'')) AS dni,
            NULLIF(mail,'') AS email,
            CASE WHEN tel_clean IS NULL OR tel_clean = '' THEN NULL
                 ELSE LEFT(tel_clean, 12) END AS telefono,
            CASE WHEN cbu_digits IS NULL OR LEN(cbu_digits) <> 22 THEN NULL
                 ELSE CONVERT(CHAR(22), cbu_digits) END AS cbu_cvu
        FROM cbu
        WHERE TRY_CONVERT(INT, NULLIF(dni_s,'')) IS NOT NULL
          AND NULLIF(nom,'') IS NOT NULL
          AND NULLIF(ape,'') IS NOT NULL;

        /* 3) Normalizar emails duplicados (evitar violar UNIQUE) */
        IF OBJECT_ID('tempdb..#Stg2','U') IS NOT NULL DROP TABLE #Stg2;
        CREATE TABLE #Stg2
        (
            nombre     VARCHAR(50)  COLLATE Latin1_General_CI_AI NOT NULL,
            apellido   VARCHAR(50)  COLLATE Latin1_General_CI_AI NOT NULL,
            dni        INT          NOT NULL,
            email      VARCHAR(100) COLLATE Latin1_General_CI_AI NULL,
            telefono   VARCHAR(12)  COLLATE Latin1_General_CI_AI NULL,
            cbu_cvu    CHAR(22)     COLLATE Latin1_General_CI_AI NULL
        );

        INSERT INTO #Stg2 (nombre, apellido, dni, email, telefono, cbu_cvu)
        SELECT s.nombre, s.apellido, s.dni,
               CASE
                    WHEN s.email IS NULL THEN NULL
                    WHEN EXISTS (SELECT 1 FROM app.Tbl_Persona p WHERE p.email = s.email AND p.dni <> s.dni)
                         THEN NULL
                    ELSE s.email
               END AS email,
               s.telefono,
               s.cbu_cvu
        FROM #Stg s;

        /* 4) UPSERT por DNI */
        -- UPDATE
        UPDATE p
           SET p.nombre   = s.nombre,
               p.apellido = s.apellido,
               p.dni      = s.dni,
               p.email    = COALESCE(s.email, p.email),
               p.telefono = COALESCE(s.telefono, p.telefono),
               p.CBU_CVU  = COALESCE(s.cbu_cvu, p.CBU_CVU)
        FROM app.Tbl_Persona p
        JOIN #Stg2 s ON s.dni = p.dni;

        DECLARE @rowsUpd INT = @@ROWCOUNT;

        -- INSERT (los que no existen por DNI)
        INSERT INTO app.Tbl_Persona (nombre, apellido, dni, email, telefono, CBU_CVU)
        SELECT s.nombre, s.apellido, s.dni, s.email, s.telefono, s.cbu_cvu
        FROM #Stg2 s
        WHERE NOT EXISTS (SELECT 1 FROM app.Tbl_Persona p WHERE p.dni = s.dni);

        DECLARE @rowsIns INT = @@ROWCOUNT;

        /* 5) Resultado */
        SELECT
            filas_csv      = (SELECT COUNT(*) FROM #Raw),
            filas_validas  = (SELECT COUNT(*) FROM #Stg2),
            personas_upd   = @rowsUpd,
            personas_ins   = @rowsIns,
            msg            = N'OK: Personas cargadas por DNI (email único protegido, tel/CBU normalizados).';
    END TRY
    BEGIN CATCH
        
    END CATCH
END;
GO

EXEC importacion.Sp_CargarPersonasDesdeCsvDatos
    @RutaArchivo   = N'C:\Users\PC\Desktop\consorcios\Inquilino-propietarios-datos.csv',
    @HDR           = 1,
    @RowTerminator = N'0x0d0a',  -- si no levanta, probá N'0x0a'
    @CodePage      = N'ACP';     -- si el archivo es UTF-8, poné N'65001'

SELECT * FROM app.Tbl_Persona;
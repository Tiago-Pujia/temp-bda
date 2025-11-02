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
            -- Si tu archivo agrega rol y fechas, podés sumar columnas aquí:
            -- ,[rol]              NVARCHAR(50)  NULL  -- 'Inquilino'/'Propietario'
            -- ,[fechaInicio]      NVARCHAR(50)  NULL
            -- ,[fechaFin]         NVARCHAR(50)  NULL
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
            departamento      CHAR(1)     COLLATE Latin1_General_CI_AI NULL,
            cbu_cvu_csv       VARCHAR(30) NULL
            --,rolCsv          VARCHAR(50) NULL
            --,fechaInicioCsv  DATE        NULL
            --,fechaFinCsv     DATE        NULL
        );

        INSERT INTO #Stg (idUnidadFuncional, nombre, piso, departamento, cbu_cvu_csv /*,rolCsv,fechaInicioCsv,fechaFinCsv*/)
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
                                END,
            cbu_cvu_csv       = NULLIF(LTRIM(RTRIM(REPLACE(REPLACE([CVU/CBU], ' ', ''), '-', ''))), '')
            --,rolCsv           = NULLIF(LTRIM(RTRIM([rol])), '')
            --,fechaInicioCsv   = TRY_CONVERT(DATE, NULLIF(LTRIM(RTRIM([fechaInicio])), ''))
            --,fechaFinCsv      = TRY_CONVERT(DATE, NULLIF(LTRIM(RTRIM([fechaFin])), ''))
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
        SELECT idUnidadFuncional, nombre, piso, departamento, cbu_cvu_csv /*,rolCsv,fechaInicioCsv,fechaFinCsv*/
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

        /* 4c) NUEVO: relacionar UF con Persona por CBU/CVU e insertar en Tbl_UFPersona */
;WITH personas AS (
    SELECT
        p.idPersona,
        REPLACE(REPLACE(LTRIM(RTRIM(p.CBU_CVU)), ' ', ''), '-', '') AS cbu_norm
    FROM app.Tbl_Persona p
    WHERE p.CBU_CVU IS NOT NULL
),
stg AS (
    SELECT
        s.idUnidadFuncional,
        s.nombre COLLATE Modern_Spanish_CI_AS AS nombre,
        s.cbu_cvu_csv AS cbu_csv_norm,
        s.piso, s.departamento
    FROM #StgDedup s
    WHERE s.cbu_cvu_csv IS NOT NULL
),
matchUF AS (
    SELECT
        u.idUnidadFuncional,
        u.idConsorcio
    FROM app.Tbl_UnidadFuncional u
)
INSERT INTO app.Tbl_UFPersona (idPersona, idUnidadFuncional, idConsorcio, esInquilino, fechaInicio, fechaFin)
SELECT DISTINCT
    per.idPersona,
    s.idUnidadFuncional,
    u.idConsorcio,
    /* esInquilino */ NULL,
    /* fechaInicio */ NULL,
    /* fechaFin    */ NULL
FROM stg s
JOIN personas per
  ON per.cbu_norm COLLATE Latin1_General_CI_AI = s.cbu_csv_norm COLLATE Latin1_General_CI_AI
JOIN app.Tbl_Consorcio c
  ON c.nombre COLLATE Modern_Spanish_CI_AS = s.nombre COLLATE Modern_Spanish_CI_AS
JOIN matchUF u
  ON u.idUnidadFuncional = s.idUnidadFuncional
 AND u.idConsorcio = c.idConsorcio
WHERE NOT EXISTS (
    SELECT 1
    FROM app.Tbl_UFPersona up
    WHERE up.idPersona = per.idPersona
      AND up.idUnidadFuncional = s.idUnidadFuncional
);


        DECLARE @rowsUFPersona INT = @@ROWCOUNT;

        /* 5) Resultado */
        SELECT
            filas_csv            = (SELECT COUNT(*) FROM #RawUF),
            filas_tipadas        = (SELECT COUNT(*) FROM #Stg),
            filas_dedup          = (SELECT COUNT(*) FROM #StgDedup),
            dups_en_csv          = (SELECT dups_en_csv FROM #CsvDupCount),
            consorcios_nuevos    = (SELECT COUNT(*) FROM @insCons),
            ufs_actualizadas     = @rowsUpd,
            ufs_insertadas       = @rowsIns,
            ufpersonas_insertadas= @rowsUFPersona,
            mensaje              = N'OK: Consorcios/UF listos y UFPersona insertado por CBU/CVU. PB => piso 0';
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
        DECLARE @ErrMsg NVARCHAR(4000) = ERROR_MESSAGE();
        RAISERROR(@ErrMsg, 16, 1);
    END CATCH
END;
GO

EXEC importacion.Sp_CargarUFsDesdeTxt
    @RutaArchivo   = N'C:\Users\PC\Desktop\consorcios\UF por consorcio.txt',
    @HDR           = 1,              -- 0 si NO hay encabezado
    @RowTerminator = N'0x0d0a',      -- probá N'0x0a' si no levanta
    @CodePage      = N'65001';       -- si ves acentos raros, probá N'ACP'

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
        DECLARE @ErrMsg NVARCHAR(4000) = ERROR_MESSAGE();
        RAISERROR(@ErrMsg, 16, 1);
    END CATCH
END;
GO

IF OBJECT_ID(N'importacion.Sp_CargarUFInquilinosDesdeCsv', N'P') IS NOT NULL
    DROP PROCEDURE importacion.Sp_CargarUFInquilinosDesdeCsv;
GO
CREATE PROCEDURE importacion.Sp_CargarUFInquilinosDesdeCsv
    @RutaArchivo    NVARCHAR(4000),            -- ej: N'C:\...\Inquilino-propietarios-datos.csv'
    @HDR            BIT = 1,                   -- 1 = primera fila encabezado
    @RowTerminator  NVARCHAR(10) = N'0x0d0a',  -- CRLF (usar '0x0a' si solo LF)
    @CodePage       NVARCHAR(16) = N'ACP',     -- latin1; usar '65001' si UTF-8
    @SoloPreview    BIT = 1                    -- 1 = NO actualiza; 0 = actualiza
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @FirstRow INT = CASE WHEN @HDR=1 THEN 2 ELSE 1 END;

    -- 1) RAW tal cual del CSV (usa ';' y latin1 por defecto)
    IF OBJECT_ID('tempdb..#Raw','U') IS NOT NULL DROP TABLE #Raw;
    CREATE TABLE #Raw
    (
        [Nombre]                 NVARCHAR(255) COLLATE Latin1_General_CI_AI NULL,
        [apellido]               NVARCHAR(255) COLLATE Latin1_General_CI_AI NULL,
        [DNI]                    NVARCHAR(50)  COLLATE Latin1_General_CI_AI NULL,
        [email personal]         NVARCHAR(255) COLLATE Latin1_General_CI_AI NULL,
        [telfono de contacto]   NVARCHAR(255) COLLATE Latin1_General_CI_AI NULL, -- viene así
        [CVU/CBU]                NVARCHAR(64)  COLLATE Latin1_General_CI_AI NULL,
        [Inquilino]              NVARCHAR(50)  COLLATE Latin1_General_CI_AI NULL
    );

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

    DECLARE @filasRaw INT = (SELECT COUNT(*) FROM #Raw);
    RAISERROR(N'[CSV] Filas leídas: %d', 0, 1, @filasRaw) WITH NOWAIT;

    -- 2) STAGING: limpiar CBU/CBU → 22 dígitos y mapear Inquilino → BIT
    IF OBJECT_ID('tempdb..#Stg','U') IS NOT NULL DROP TABLE #Stg;
    CREATE TABLE #Stg
    (
        cbu_cvu     CHAR(22)    COLLATE Latin1_General_CI_AI NOT NULL,
        esInquilino BIT         NOT NULL
    );

    ;WITH s AS
    (
        SELECT
            cbu_digits = REPLACE(REPLACE(REPLACE(REPLACE(REPLACE(REPLACE(REPLACE(REPLACE(REPLACE(REPLACE(
                             LTRIM(RTRIM([CVU/CBU])),' ',''),'-',''),'.',''),'/',''),'\',''),'_',''),
                             '(' ,''),')',''),CHAR(9),''),CHAR(160),''),
            inq_raw    = LTRIM(RTRIM([Inquilino]))
        FROM #Raw
    )
    INSERT INTO #Stg(cbu_cvu, esInquilino)
    SELECT DISTINCT
        CONVERT(CHAR(22), s.cbu_digits),
        CASE 
            WHEN LOWER(s.inq_raw) COLLATE Latin1_General_CI_AI IN (N'si',N'sí',N'true',N'1',N'inquilino') THEN 1
            WHEN LOWER(s.inq_raw) COLLATE Latin1_General_CI_AI IN (N'no',N'false',N'0',N'propietario') THEN 0
        END
    FROM s
    WHERE s.cbu_digits IS NOT NULL
      AND s.cbu_digits NOT LIKE '%[^0-9]%'
      AND LEN(s.cbu_digits)=22
      AND inq_raw IS NOT NULL
      AND LOWER(inq_raw) COLLATE Latin1_General_CI_AI IN (N'si',N'sí',N'true',N'1',N'inquilino', N'no',N'false',N'0',N'propietario');

    DECLARE @filasStg INT = (SELECT COUNT(*) FROM #Stg);
    RAISERROR(N'[STG] Filas válidas (CBU 22 dígitos + Inquilino mapeado): %d', 0, 1, @filasStg) WITH NOWAIT;

    -- 2.a) Preview: ver lo que se leyó y cómo queda mapeado
    SELECT TOP (20)
        [CVU/CBU]          AS cbu_csv,
        [Inquilino]        AS inquilino_csv,
        CASE WHEN LOWER([Inquilino]) COLLATE Latin1_General_CI_AI IN (N'si',N'sí',N'true',N'1',N'inquilino') THEN 1
             WHEN LOWER([Inquilino]) COLLATE Latin1_General_CI_AI IN (N'no',N'false',N'0',N'propietario') THEN 0
        END                 AS esInquilino_mapeado
    FROM #Raw;

    -- 3) Resolver personas por CBU/CVU
    IF OBJECT_ID('tempdb..#MatchPersona','U') IS NOT NULL DROP TABLE #MatchPersona;
    CREATE TABLE #MatchPersona
    (
        idPersona INT NOT NULL,
        cbu_cvu   CHAR(22) COLLATE Latin1_General_CI_AI NOT NULL,
        esInquilino BIT NOT NULL
    );

    INSERT INTO #MatchPersona(idPersona, cbu_cvu, esInquilino)
    SELECT p.idPersona, st.cbu_cvu, st.esInquilino
    FROM #Stg st
    JOIN app.Tbl_Persona p
      ON p.CBU_CVU = st.cbu_cvu;

    DECLARE @matchPersona INT = (SELECT COUNT(*) FROM #MatchPersona);
    RAISERROR(N'[MATCH] Personas encontradas por CBU/CVU: %d', 0, 1, @matchPersona) WITH NOWAIT;

    -- 3.a) CBUs que NO tienen persona (para saber por qué no actualiza)
    SELECT TOP (20) st.cbu_cvu
    FROM #Stg st
    WHERE NOT EXISTS (SELECT 1 FROM app.Tbl_Persona p WHERE p.CBU_CVU = st.cbu_cvu);

    -- 4) Resolver UF vinculadas a esas personas
    IF OBJECT_ID('tempdb..#MatchUF','U') IS NOT NULL DROP TABLE #MatchUF;
    CREATE TABLE #MatchUF
    (
        idPersona         INT NOT NULL,
        idUnidadFuncional INT NOT NULL,
        esInquilino       BIT NOT NULL
    );

    INSERT INTO #MatchUF(idPersona, idUnidadFuncional, esInquilino)
    SELECT mp.idPersona, ufp.idUnidadFuncional, mp.esInquilino
    FROM #MatchPersona mp
    JOIN app.Tbl_UFPersona ufp
      ON ufp.idPersona = mp.idPersona;

    DECLARE @matchUF INT = (SELECT COUNT(*) FROM #MatchUF);
    RAISERROR(N'[MATCH] Relaciones UFPersona encontradas para esas personas: %d', 0, 1, @matchUF) WITH NOWAIT;

    -- 4.a) Personas con CBU que NO tienen filas en UFPersona (causa típica de 0 updates)
    SELECT TOP (20) mp.idPersona, mp.cbu_cvu
    FROM #MatchPersona mp
    WHERE NOT EXISTS (
        SELECT 1 FROM app.Tbl_UFPersona ufp WHERE ufp.idPersona = mp.idPersona
    );

    -- 5) UPDATE (opcional)
    IF (@SoloPreview = 0)
    BEGIN
        UPDATE ufp
           SET ufp.esInquilino = muf.esInquilino
        FROM app.Tbl_UFPersona ufp
        JOIN #MatchUF muf
          ON muf.idPersona = ufp.idPersona
         AND muf.idUnidadFuncional = ufp.idUnidadFuncional;

        DECLARE @rowsUpd INT = @@ROWCOUNT;
        RAISERROR(N'[UPDATE] Filas actualizadas en Tbl_UFPersona: %d', 0, 1, @rowsUpd) WITH NOWAIT;
    END
    ELSE
    BEGIN
        RAISERROR(N'[PREVIEW] No se actualiza (usar @SoloPreview=0 para aplicar cambios).', 0, 1) WITH NOWAIT;
        -- Preview de lo que se actualizaría
        SELECT TOP (50)
            ufp.idPersona, ufp.idUnidadFuncional,
            ufp.esInquilino AS esInquilino_actual,
            muf.esInquilino AS esInquilino_nuevo
        FROM app.Tbl_UFPersona ufp
        JOIN #MatchUF muf
          ON muf.idPersona = ufp.idPersona
         AND muf.idUnidadFuncional = ufp.idUnidadFuncional;
    END

    -- 6) Resumen final
    SELECT
        filas_csv_total               = @filasRaw,
        filas_validas_stg             = @filasStg,
        personas_con_cbu              = @matchPersona,
        uf_relaciones_encontradas     = @matchUF,
        nota                          = CASE WHEN @SoloPreview=1 THEN 'Preview: no se actualiza'
                                             ELSE 'Aplicado: esInquilino actualizado'
                                        END;
END;
GO

IF OBJECT_ID('dbo.fn_ParseImporteFlexible', 'FN') IS NOT NULL
    DROP FUNCTION dbo.fn_ParseImporteFlexible;
GO
CREATE FUNCTION dbo.fn_ParseImporteFlexible (@s NVARCHAR(100))
RETURNS DECIMAL(18,2)
AS
BEGIN
    -- Normalización previa (quita NBSP, $, ARS, espacios, tabs)
    DECLARE @t NVARCHAR(100) =
        REPLACE(REPLACE(REPLACE(REPLACE(REPLACE(ISNULL(@s,N''), CHAR(160), ' '), 'ARS', ''), '$', ''), ' ', ''), CHAR(9), '');

    -- Negativos tipo (123,45)
    IF LEFT(@t,1)='(' AND RIGHT(@t,1)=')'
        SET @t = '-' + SUBSTRING(@t,2,LEN(@t)-2);

    DECLARE @res DECIMAL(18,2);

    -- Estilo US: 120,000.00
    SET @res = TRY_CONVERT(DECIMAL(18,2), REPLACE(@t, ',', ''));
    IF @res IS NOT NULL RETURN @res;

    -- Estilo EU: 33.706,04
    SET @res = TRY_CONVERT(DECIMAL(18,2), REPLACE(REPLACE(@t, '.', ''), ',', '.'));
    IF @res IS NOT NULL RETURN @res;

    -- Fallback: dejar dígitos y . , -
    DECLARE @u NVARCHAR(100) = N'';
    DECLARE @i INT = 1, @c NCHAR(1);
    WHILE @i <= LEN(@t)
    BEGIN
        SET @c = SUBSTRING(@t, @i, 1);
        IF @c LIKE N'[0-9]' OR @c IN (N'.', N',', N'-')
            SET @u = @u + @c;
        SET @i += 1;
    END

    -- Elegir separador decimal: el último que aparezca (.,)
    DECLARE @pDot INT = NULLIF(CHARINDEX('.', REVERSE(@u)), 0);
    DECLARE @pCom INT = NULLIF(CHARINDEX(',', REVERSE(@u)), 0);
    DECLARE @sep NCHAR(1) =
        CASE WHEN @pDot IS NOT NULL AND (@pCom IS NULL OR @pDot < @pCom) THEN '.'
             WHEN @pCom IS NOT NULL THEN ','
             ELSE '.'
        END;

    IF @sep='.'
        SET @u = REPLACE(@u, ',', '');
    ELSE
        SET @u = REPLACE(REPLACE(@u, '.', ''), ',', '.');

    RETURN TRY_CONVERT(DECIMAL(18,2), @u);
END
GO

ALTER PROCEDURE importacion.Sp_CargarGastosDesdeJson
    @RutaArchivo NVARCHAR(4000),
    @Anio INT,
    @DiaVto1 TINYINT = 10,
    @DiaVto2 TINYINT = 20
AS
BEGIN
    SET NOCOUNT ON;

    /* 1) Leer JSON */
    DECLARE @json NVARCHAR(MAX);
    DECLARE @sql NVARCHAR(MAX) = N'
        SELECT @jsonOut = BulkColumn
        FROM OPENROWSET (BULK ''' + REPLACE(@RutaArchivo, '''', '''''') + ''', SINGLE_CLOB) AS j
    ';
    EXEC sp_executesql @sql, N'@jsonOut NVARCHAR(MAX) OUTPUT', @jsonOut = @json OUTPUT;

    IF @json IS NULL
    BEGIN
        RAISERROR('No se pudo leer el archivo JSON con OPENROWSET. Verificá ruta/permisos y que Ad Hoc Distributed Queries esté habilitado.', 16, 1);
        RETURN;
    END

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
        LTRIM(RTRIM(consorcio)) COLLATE DATABASE_DEFAULT,
        LTRIM(RTRIM(mes_raw))   COLLATE DATABASE_DEFAULT,
        v.categoria             COLLATE DATABASE_DEFAULT,
        LTRIM(RTRIM(importe_raw)) COLLATE DATABASE_DEFAULT,
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
            ELSE dbo.fn_ParseImporteFlexible(importe_raw)
        END
    FROM unpvt v
    WHERE NULLIF(LTRIM(RTRIM(consorcio)), N'') IS NOT NULL;

    /* Avisos */
    DECLARE @filasDescartadas INT;
    ;WITH rows2 AS (SELECT CAST([value] AS NVARCHAR(MAX)) AS obj FROM OPENJSON(@json))
    SELECT @filasDescartadas = COUNT(1)
    FROM rows2
    WHERE NULLIF(LTRIM(RTRIM(JSON_VALUE(obj, '$."Nombre del consorcio"'))), N'') IS NULL;
    IF @filasDescartadas > 0
        PRINT CONCAT('Advertencia: ', @filasDescartadas, ' filas descartadas por consorcio NULL o vacío.');
    IF EXISTS (SELECT 1 FROM #stg_gasto WHERE importe_raw IS NOT NULL AND importe IS NULL)
        PRINT 'Advertencia: hay importes que no se pudieron convertir. Revisar #stg_gasto.';

    /* 4) Mapa extraordinario (editable) */
    IF OBJECT_ID('tempdb..#map_extra') IS NOT NULL DROP TABLE #map_extra;
    CREATE TABLE #map_extra (categoria NVARCHAR(100) COLLATE DATABASE_DEFAULT PRIMARY KEY);
    -- INSERT INTO #map_extra(categoria) VALUES (N'GASTOS GENERALES');

    /* 5) Consorcios */
    ;WITH cte_cons AS (
        SELECT DISTINCT consorcio FROM #stg_gasto
        WHERE consorcio IS NOT NULL AND consorcio <> N''
    )
    INSERT INTO app.Tbl_Consorcio (nombre, direccion, superficieTotal)
    SELECT c.consorcio, NULL, NULL
    FROM cte_cons c
    LEFT JOIN app.Tbl_Consorcio tc ON tc.nombre = c.consorcio COLLATE DATABASE_DEFAULT
    WHERE tc.idConsorcio IS NULL;

    IF OBJECT_ID('tempdb..#cons') IS NOT NULL DROP TABLE #cons;
    SELECT c.consorcio, tc.idConsorcio
    INTO #cons
    FROM (SELECT DISTINCT consorcio FROM #stg_gasto) c
    INNER JOIN app.Tbl_Consorcio tc ON tc.nombre = c.consorcio COLLATE DATABASE_DEFAULT;

    /* 6) Expensas */
    IF OBJECT_ID('tempdb..#exp_sum') IS NOT NULL DROP TABLE #exp_sum;
    SELECT cn.idConsorcio, s.mes, SUM(s.importe) AS total
    INTO #exp_sum
    FROM #stg_gasto s
    INNER JOIN #cons cn ON cn.consorcio = s.consorcio COLLATE DATABASE_DEFAULT
    WHERE s.importe IS NOT NULL AND s.mes BETWEEN 1 AND 12
    GROUP BY cn.idConsorcio, s.mes;

    IF OBJECT_ID('tempdb..#exp') IS NOT NULL DROP TABLE #exp;
    CREATE TABLE #exp (idConsorcio INT, mes TINYINT, nroExpensa INT);

    DECLARE cur CURSOR LOCAL FAST_FORWARD FOR
        SELECT idConsorcio, mes, total FROM #exp_sum;
    DECLARE @idC INT, @mes TINYINT, @total DECIMAL(18,2);
    OPEN cur;
    FETCH NEXT FROM cur INTO @idC, @mes, @total;
    WHILE @@FETCH_STATUS = 0
    BEGIN
        DECLARE @fechaGen DATE = DATEFROMPARTS(@Anio, @mes, 1);
        DECLARE @finMes  DATE = EOMONTH(@fechaGen);
        DECLARE @v1 DATE = IIF(@DiaVto1 IS NULL, @finMes, DATEFROMPARTS(@Anio, @mes, IIF(@DiaVto1 > DAY(@finMes), DAY(@finMes), @DiaVto1)));
        DECLARE @v2 DATE = IIF(@DiaVto2 IS NULL, @finMes, DATEFROMPARTS(@Anio, @mes, IIF(@DiaVto2 > DAY(@finMes), DAY(@finMes), @DiaVto2)));

        DECLARE @nroExp INT;

        SELECT @nroExp = e.nroExpensa
        FROM app.Tbl_Expensa e
        WHERE e.idConsorcio = @idC AND e.fechaGeneracion = @fechaGen;

        IF @nroExp IS NULL
        BEGIN
            INSERT INTO app.Tbl_Expensa (idConsorcio, fechaGeneracion, fechaVto1, fechaVto2, montoTotal)
            VALUES (@idC, @fechaGen, @v1, @v2, @total);
            SET @nroExp = SCOPE_IDENTITY();
        END
        ELSE
        BEGIN
            UPDATE app.Tbl_Expensa
               SET montoTotal = @total,
                   fechaVto1  = @v1,
                   fechaVto2  = @v2
             WHERE nroExpensa = @nroExp;
        END

        INSERT INTO #exp(idConsorcio, mes, nroExpensa) VALUES (@idC, @mes, @nroExp);
        FETCH NEXT FROM cur INTO @idC, @mes, @total;
    END
    CLOSE cur; DEALLOCATE cur;

    /* 7) Insertar Gastos + salida para subtablas (MERGE) */
    IF OBJECT_ID('tempdb..#ins') IS NOT NULL DROP TABLE #ins;
    CREATE TABLE #ins (
        idGasto   INT NOT NULL,
        categoria NVARCHAR(100) COLLATE DATABASE_DEFAULT NOT NULL
    );

    MERGE app.Tbl_Gasto AS tgt
    USING (
        SELECT 
            e.nroExpensa                                    AS nroExpensa,
            c.idConsorcio                                   AS idConsorcio,
            CASE WHEN mx.categoria IS NOT NULL 
                 THEN 'Extraordinario' ELSE 'Ordinario' END AS tipo,
            -- Descripción exacta desde JSON: la categoría, sin "(mes año)"
            s.categoria COLLATE DATABASE_DEFAULT            AS descripcion,
            DATEFROMPARTS(@Anio, s.mes, 1)                  AS fechaEmision,
            s.importe                                       AS importe,
            s.categoria COLLATE DATABASE_DEFAULT            AS categoria
        FROM #stg_gasto s
        INNER JOIN #cons c  ON c.consorcio = s.consorcio COLLATE DATABASE_DEFAULT
        INNER JOIN #exp e   ON e.idConsorcio = c.idConsorcio AND e.mes = s.mes
        LEFT  JOIN #map_extra mx ON mx.categoria = s.categoria COLLATE DATABASE_DEFAULT
        WHERE s.importe IS NOT NULL AND s.mes BETWEEN 1 AND 12
    ) AS src
    ON 1 = 0
    WHEN NOT MATCHED THEN
        INSERT (nroExpensa, idConsorcio, tipo, descripcion, fechaEmision, importe)
        VALUES (src.nroExpensa, src.idConsorcio, src.tipo, src.descripcion, src.fechaEmision, src.importe)
    OUTPUT INSERTED.idGasto, src.categoria INTO #ins(idGasto, categoria);

    /* 8) Subtablas */
    INSERT INTO app.Tbl_Gasto_Ordinario (idGasto, nombreProveedor, categoria, nroFactura)
    SELECT i.idGasto, NULL, i.categoria, NULL
    FROM #ins i
    LEFT JOIN #map_extra mx ON mx.categoria = i.categoria COLLATE DATABASE_DEFAULT
    WHERE mx.categoria IS NULL;

    INSERT INTO app.Tbl_Gasto_Extraordinario (idGasto, cuotaActual, cantCuotas)
    SELECT i.idGasto, 1, 1
    FROM #ins i
    INNER JOIN #map_extra mx ON mx.categoria = i.categoria COLLATE DATABASE_DEFAULT;

    PRINT 'Proceso finalizado OK (importes corregidos y descripción sin "mes año").';
END
GO

EXEC importacion.Sp_CargarGastosDesdeJson
     @RutaArchivo = N'C:\Users\PC\Desktop\consorcios\Servicios.Servicios.json',  -- <- tu ruta local
     @Anio        = 2025,
     @DiaVto1     = 10,
     @DiaVto2     = 20;

---------------------------------------------------------

IF OBJECT_ID(N'importacion.Sp_CargarPagosDesdeCsv', N'P') IS NOT NULL
    DROP PROCEDURE importacion.Sp_CargarPagosDesdeCsv;
GO

CREATE PROCEDURE importacion.Sp_CargarPagosDesdeCsv
    @RutaArchivo      NVARCHAR(4000),      -- Ej: N'C:\Data\pagos_consorcios.csv'
    @HDR              BIT = 1,             -- 1 = primera fila encabezado; 0 = no
    @Separador        CHAR(1) = ',',       -- separador de campos
    @MostrarErrores   BIT = 0              -- 0 = no muestra; 1 = muestra (sin "motivo")
AS
BEGIN
    SET NOCOUNT ON;

    -- Limpieza previa
    IF OBJECT_ID('tempdb..#raw')                IS NOT NULL DROP TABLE #raw;
    IF OBJECT_ID('tempdb..#norm')               IS NOT NULL DROP TABLE #norm;
    IF OBJECT_ID('tempdb..#pagos')              IS NOT NULL DROP TABLE #pagos;
    IF OBJECT_ID('tempdb..#errores')            IS NOT NULL DROP TABLE #errores;
    IF OBJECT_ID('tempdb..#pagos_completos')    IS NOT NULL DROP TABLE #pagos_completos;

    -- Raw ancho (acepta 3, 4 o más columnas)
    CREATE TABLE #raw (
        c1 NVARCHAR(4000) COLLATE DATABASE_DEFAULT NULL,
        c2 NVARCHAR(4000) COLLATE DATABASE_DEFAULT NULL,
        c3 NVARCHAR(4000) COLLATE DATABASE_DEFAULT NULL,
        c4 NVARCHAR(4000) COLLATE DATABASE_DEFAULT NULL,
        c5 NVARCHAR(4000) COLLATE DATABASE_DEFAULT NULL,
        c6 NVARCHAR(4000) COLLATE DATABASE_DEFAULT NULL
    );

    -- Mapeo flexible a 4 campos lógicos (id opcional)
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

    -- Se usa internamente; no se devuelve salvo que @MostrarErrores=1
    CREATE TABLE #errores (
        motivo      NVARCHAR(200)  COLLATE DATABASE_DEFAULT,
        fecha_txt   NVARCHAR(4000) COLLATE DATABASE_DEFAULT,
        cbu_txt     NVARCHAR(4000) COLLATE DATABASE_DEFAULT,
        valor_txt   NVARCHAR(4000) COLLATE DATABASE_DEFAULT
    );

    -- BULK INSERT
    DECLARE @firstrow INT = CASE WHEN @HDR = 1 THEN 2 ELSE 1 END;

    DECLARE @sql NVARCHAR(MAX) = N'
BULK INSERT #raw
FROM ' + QUOTENAME(@RutaArchivo,'''') + N'
WITH (
    FIRSTROW = ' + CAST(@firstrow AS NVARCHAR(10)) + N',
    FIELDTERMINATOR = ' + QUOTENAME(@Separador,'''') + N',
    ROWTERMINATOR = ''0x0a'',
    CODEPAGE = ''65001'',
    TABLOCK
);';

    BEGIN TRY
        EXEC sp_executesql @sql;
    END TRY
    BEGIN CATCH
        DECLARE @msg NVARCHAR(4000) = ERROR_MESSAGE();
        RAISERROR(N'Error al leer el CSV con BULK INSERT: %s. Verifique permisos/visibilidad de la ruta para el servicio de SQL Server.', 16, 1, @msg);
        RETURN;
    END CATCH;

    /* ===== 1) Normalización flexible de columnas ===== */
    INSERT INTO #norm (id_pago_txt, fecha_txt, cbu_txt, valor_txt)
    SELECT
        CASE WHEN NULLIF(LTRIM(RTRIM(c4)),'') IS NOT NULL THEN c1 ELSE NULL END,
        CASE WHEN NULLIF(LTRIM(RTRIM(c4)),'') IS NOT NULL THEN c2 ELSE c1 END,
        CASE WHEN NULLIF(LTRIM(RTRIM(c4)),'') IS NOT NULL THEN c3 ELSE c2 END,
        CASE WHEN NULLIF(LTRIM(RTRIM(c4)),'') IS NOT NULL THEN c4 ELSE c3 END
    FROM #raw;

    /* ===== 2) Parseo robusto de fecha y valor ===== */
    ;WITH pre AS (
        SELECT
            fecha_txt,
            cbu_txt,
            valor_txt,
            LTRIM(RTRIM(
                REPLACE(REPLACE(REPLACE(valor_txt, NCHAR(160), N' '), CHAR(9), N' '), N'$', N'')
            )) AS v0
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
            fecha_txt,
            cbu_txt,
            valor_txt,
            CASE WHEN CHARINDEX(' ', v1) > 0 THEN LEFT(v1, CHARINDEX(' ', v1)-1) ELSE v1 END AS v_num_txt
        FROM norm_val
    ),
    parsed AS (
        SELECT
            COALESCE(
               TRY_CONVERT(date, NULLIF(LTRIM(RTRIM(fecha_txt)),''), 103),
               TRY_CONVERT(date, NULLIF(LTRIM(RTRIM(fecha_txt)),''), 120),
               TRY_CONVERT(date, NULLIF(LTRIM(RTRIM(fecha_txt)),''))) AS fecha,
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

    /* ===== 2b) Errores de parseo (internos; no se devuelven por defecto) ===== */
    INSERT INTO #errores (motivo, fecha_txt, cbu_txt, valor_txt)
    SELECT
        N'Fila inválida (fecha/valor/CBU)',
        n.fecha_txt,
        n.cbu_txt,
        n.valor_txt
    FROM #norm n
    CROSS APPLY (SELECT LTRIM(RTRIM(REPLACE(REPLACE(REPLACE(n.valor_txt, NCHAR(160), N' '), CHAR(9), N' '), N'$', N''))) AS v0) a
    CROSS APPLY (SELECT REPLACE(REPLACE(a.v0, N'.', N''), N',', N'.') AS v1) b
    CROSS APPLY (SELECT CASE WHEN CHARINDEX(' ', b.v1) > 0 THEN LEFT(b.v1, CHARINDEX(' ', b.v1)-1) ELSE b.v1 END AS v_num_txt) c
    WHERE
        COALESCE(
           TRY_CONVERT(date, NULLIF(LTRIM(RTRIM(n.fecha_txt)),''), 103),
           TRY_CONVERT(date, NULLIF(LTRIM(RTRIM(n.fecha_txt)),''), 120),
           TRY_CONVERT(date, NULLIF(LTRIM(RTRIM(n.fecha_txt)),''))) IS NULL
        OR TRY_CONVERT(decimal(10,2), c.v_num_txt) IS NULL
        OR NULLIF(LTRIM(RTRIM(n.cbu_txt)),'') IS NULL;

    /* ===== 3) Resolver claves y completar pagos ===== */
    ;WITH pagos_enriq AS (
        SELECT
            p.fecha,
            p.CBU_CVU,
            p.valor,
            per.idPersona,
            ufper.idUnidadFuncional AS nroUnidadFuncional,
            ufper.idConsorcio
        FROM #pagos p
        LEFT JOIN app.Tbl_Persona   per   ON per.CBU_CVU       = p.CBU_CVU
        LEFT JOIN app.Tbl_UFPersona ufper ON ufper.idPersona   = per.idPersona
    )
    SELECT
        pe.*,
        (SELECT TOP (1) e.nroExpensa
           FROM app.Tbl_Expensa e
          WHERE e.idConsorcio = pe.idConsorcio
          ORDER BY e.fechaGeneracion DESC, e.nroExpensa DESC) AS nroExpensa
    INTO #pagos_completos
    FROM pagos_enriq pe;

    -- Faltantes (interno)
    INSERT INTO #errores (motivo, fecha_txt, cbu_txt, valor_txt)
    SELECT
        CASE 
          WHEN idPersona IS NULL THEN N'CBU no existe en Tbl_Persona'
          WHEN nroUnidadFuncional IS NULL THEN N'Persona sin relación UF (Tbl_UFPersona)'
          WHEN idConsorcio IS NULL THEN N'No se determinó Consorcio'
          WHEN nroExpensa IS NULL THEN N'No hay expensa para el consorcio'
        END,
        CONVERT(NVARCHAR(30), fecha, 121),
        CBU_CVU, CONVERT(NVARCHAR(40), valor)
    FROM #pagos_completos
    WHERE idPersona IS NULL
       OR nroUnidadFuncional IS NULL
       OR idConsorcio IS NULL
       OR nroExpensa IS NULL;

    /* ===== 4) Crear EstadoCuenta (si falta) e insertar Pagos ===== */
    ;WITH base_ok AS (
        SELECT DISTINCT
            pc.nroUnidadFuncional,
            pc.idConsorcio,
            pc.nroExpensa,
            MIN(pc.fecha) OVER (PARTITION BY pc.nroUnidadFuncional, pc.idConsorcio, pc.nroExpensa) AS fecha_min
        FROM #pagos_completos pc
        WHERE pc.idPersona IS NOT NULL
          AND pc.nroUnidadFuncional IS NOT NULL
          AND pc.idConsorcio IS NOT NULL
          AND pc.nroExpensa IS NOT NULL
    )
    INSERT INTO app.Tbl_EstadoCuenta
        (nroUnidadFuncional, idConsorcio, nroExpensa,
         saldoAnterior, pagoRecibido, deuda, interesMora,
         expensasOrdinarias, expensasExtraordinarias, totalAPagar, fecha)
    SELECT
        b.nroUnidadFuncional, b.idConsorcio, b.nroExpensa,
        0, 0, 0, 0, 0, 0, 0, b.fecha_min
    FROM base_ok b
    WHERE NOT EXISTS (
        SELECT 1
        FROM app.Tbl_EstadoCuenta ec
        WHERE ec.nroUnidadFuncional = b.nroUnidadFuncional
          AND ec.idConsorcio      = b.idConsorcio
          AND ec.nroExpensa       = b.nroExpensa
    );

    INSERT INTO app.Tbl_Pago
        (idEstadoCuenta, nroUnidadFuncional, idConsorcio, nroExpensa,
         fecha, monto, CBU_CVU)
    SELECT
        ec.idEstadoCuenta,
        pc.nroUnidadFuncional,
        pc.idConsorcio,
        pc.nroExpensa,
        pc.fecha,
        pc.valor,
        pc.CBU_CVU
    FROM #pagos_completos pc
    INNER JOIN app.Tbl_EstadoCuenta ec
      ON ec.nroUnidadFuncional = pc.nroUnidadFuncional
     AND ec.idConsorcio       = pc.idConsorcio
     AND ec.nroExpensa        = pc.nroExpensa;

    -- Resultado: solo cantidad de pagos insertados
    DECLARE @insertados INT = @@ROWCOUNT;
    SELECT @insertados AS pagos_insertados;

    -- Solo si lo pedís explícitamente, muestro las filas problemáticas (sin "motivo")
    IF @MostrarErrores = 1 AND EXISTS (SELECT 1 FROM #errores)
    BEGIN
        SELECT fecha_txt, cbu_txt, valor_txt
        FROM #errores;
    END
END
GO

EXEC importacion.Sp_CargarPagosDesdeCsv
     @RutaArchivo = N'C:\Users\PC\Desktop\consorcios\pagos_consorcios.csv',
     @HDR = 1,
     @Separador = ',';

	 /** idGasto INT NOT NULL IDENTITY(1,1) PRIMARY KEY,
    nroExpensa INT NOT NULL,
    idConsorcio INT NOT NULL,
    tipo VARCHAR(16) CHECK (tipo IN ('Ordinario','Extraordinario')),
    descripcion VARCHAR(200),
    fechaEmision DATE,
    importe DECIMAL(10,2), **/

/** INSERT INTO app.Tbl_Gasto (nroExpensa, idConsorcio, tipo, descripcion, fechaEmision, importe)
VALUES 
(1, 1, 'Extraordinario', 'Reparación integral de fachada y balcones', CONVERT(date,'01/11/2025',103), 145000),
(2, 2, 'Extraordinario', 'Renovación total del sistema eléctrico del edificio', CONVERT(date,'06/07/2025',103), 230000),
(3, 3, 'Extraordinario', 'Instalación de sistema contra incendios', CONVERT(date,'22/04/2025',103), 100000),
(4, 4, 'Extraordinario', 'Impermeabilización y refacción del techo del edificio', CONVERT(date,'30/12/2025',103), 500000),
(5, 5, 'Extraordinario', 'Ampliación del área común y terminaciones completas en cerámico y luminarias', CONVERT(date,'19/08/2025',103), 210000);
GO

INSERT INTO app.Tbl_Gasto_Extraordinario (idGasto, cuotaActual, cantCuotas)
VALUES 
(1, 2, 7),
(2, 2, 5),
(3, 1, 2),
(4, 1, 1),
(5, 5, 6);
GO **/
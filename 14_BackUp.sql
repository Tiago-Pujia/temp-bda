/* ============================================================
   BACKUPS Com5600G13 - SOLUCION PARA SQL EXPRESS
   - SIN COMPRESSION (no soportado en Express)
   - Crea carpetas autom�ticamente si no existen
   - Manejo de errores completo
   ============================================================ */

/*
Archivo: 14_BackUp.sql
Propósito: Rutinas y recomendaciones para respaldos y restauraciones parciales.

Advertencias:
 - Algunos scripts usan xp_cmdshell o rutas absolute para copiar archivos; esto
     requiere permisos OS y puede ser peligroso si se ejecuta con credenciales
     elevadas.
 - Probá restauraciones en un ambiente aislado antes de aplicarlas en producción.
*/

USE master;
GO

/* 0) Asegurar esquema */
IF NOT EXISTS (SELECT 1 FROM sys.schemas WHERE name = N'maintenance')
    EXEC ('CREATE SCHEMA maintenance AUTHORIZATION dbo;');
GO

/* 1) Limpiar versiones previas */
IF OBJECT_ID(N'maintenance.usp_Backup_Com5600G13_Log',  N'P') IS NOT NULL DROP PROCEDURE maintenance.usp_Backup_Com5600G13_Log;
IF OBJECT_ID(N'maintenance.usp_Backup_Com5600G13_Diff', N'P') IS NOT NULL DROP PROCEDURE maintenance.usp_Backup_Com5600G13_Diff;
IF OBJECT_ID(N'maintenance.usp_Backup_Com5600G13_Full', N'P') IS NOT NULL DROP PROCEDURE maintenance.usp_Backup_Com5600G13_Full;
IF OBJECT_ID(N'maintenance.usp_CreateBackupFolder', N'P') IS NOT NULL DROP PROCEDURE maintenance.usp_CreateBackupFolder;
IF OBJECT_ID(N'maintenance.fn_Timestamp_yyyymmdd_hhmm', N'FN') IS NOT NULL DROP FUNCTION maintenance.fn_Timestamp_yyyymmdd_hhmm;
GO

/* 2) Funci�n timestamp */
CREATE FUNCTION maintenance.fn_Timestamp_yyyymmdd_hhmm()
RETURNS NVARCHAR(15)
AS
BEGIN
    RETURN CONVERT(NVARCHAR(8), GETDATE(), 112) + N'_' +
           REPLACE(CONVERT(NVARCHAR(8), GETDATE(), 108), N':', N'');
END
GO

/* 3) SP auxiliar: Crear carpetas (requiere xp_cmdshell habilitado) */
CREATE PROCEDURE maintenance.usp_CreateBackupFolder
    @FolderPath NVARCHAR(260)
AS
BEGIN
    SET NOCOUNT ON;
    
    DECLARE @cmd NVARCHAR(500);
    DECLARE @xpcmdEnabled INT;
    
    -- Verificar si xp_cmdshell est� habilitado
    SELECT @xpcmdEnabled = CAST(value_in_use AS INT)
    FROM sys.configurations 
    WHERE name = 'xp_cmdshell';
    
    IF @xpcmdEnabled = 0
    BEGIN
        PRINT '??  xp_cmdshell deshabilitado. Habilite temporalmente o cree carpetas manualmente.';
        PRINT 'Comando: MKDIR "' + @FolderPath + '"';
        RETURN;
    END
    
    -- Crear carpeta (no falla si ya existe)
    SET @cmd = N'IF NOT EXIST "' + @FolderPath + N'" MKDIR "' + @FolderPath + N'"';
    EXEC xp_cmdshell @cmd, NO_OUTPUT;
END
GO

/* 4) SP: BACKUP FULL (SIN COMPRESSION para Express) */
CREATE PROCEDURE maintenance.usp_Backup_Com5600G13_Full
    @FullDir NVARCHAR(260),
    @LogFile NVARCHAR(260) = NULL
AS
BEGIN
    SET NOCOUNT ON;
    
    BEGIN TRY
        -- Verificar que la base existe y est� online
        IF NOT EXISTS (SELECT 1 FROM sys.databases WHERE name = N'Com5600G13' AND state = 0)
        BEGIN
            RAISERROR(N'Base de datos Com5600G13 no disponible', 16, 1);
            RETURN;
        END
        
        -- Intentar crear carpeta
        EXEC maintenance.usp_CreateBackupFolder @FullDir;
        
        DECLARE @ts NVARCHAR(15) = maintenance.fn_Timestamp_yyyymmdd_hhmm();
        DECLARE @file NVARCHAR(4000) = @FullDir + N'\Com5600G13_FULL_' + @ts + N'.bak';
        
        -- BACKUP SIN COMPRESSION (compatible con Express)
        BACKUP DATABASE [Com5600G13]
          TO DISK = @file
          WITH INIT, CHECKSUM, STATS = 10;
        
        -- Verificaci�n
        RESTORE VERIFYONLY FROM DISK = @file WITH CHECKSUM;
        
        -- Log de �xito
        PRINT '? BACKUP FULL completado: ' + @file;
        
        IF OBJECT_ID(N'reportes.Sp_LogReporte', N'P') IS NOT NULL
            EXEC reportes.Sp_LogReporte
                 @Procedimiento = N'maintenance.usp_Backup_Com5600G13_Full',
                 @Tipo = N'INFO',
                 @Mensaje = N'BACKUP FULL OK',
                 @Detalle = @file,
                 @RutaArchivo = @file,
                 @RutaLog = @LogFile;
    END TRY
    BEGIN CATCH
        DECLARE @err NVARCHAR(4000) = ERROR_MESSAGE();
        PRINT '? ERROR en BACKUP FULL: ' + @err;
        
        IF OBJECT_ID(N'reportes.Sp_LogReporte', N'P') IS NOT NULL
            EXEC reportes.Sp_LogReporte
                 @Procedimiento = N'maintenance.usp_Backup_Com5600G13_Full',
                 @Tipo = N'ERROR',
                 @Mensaje = N'Fallo BACKUP FULL',
                 @Detalle = @err,
                 @RutaArchivo = NULL,
                 @RutaLog = @LogFile;
        
        THROW;
    END CATCH
END
GO

/* 5) SP: BACKUP DIFFERENTIAL (SIN COMPRESSION) */
CREATE PROCEDURE maintenance.usp_Backup_Com5600G13_Diff
    @DiffDir NVARCHAR(260),
    @LogFile NVARCHAR(260) = NULL
AS
BEGIN
    SET NOCOUNT ON;
    
    BEGIN TRY
        -- Verificar que existe un FULL previo
        IF NOT EXISTS (
            SELECT 1 FROM msdb.dbo.backupset 
            WHERE database_name = N'Com5600G13' 
              AND type = 'D' -- FULL
              AND backup_finish_date IS NOT NULL
        )
        BEGIN
            RAISERROR(N'No existe BACKUP FULL previo. Ejecute primero usp_Backup_Com5600G13_Full', 16, 1);
            RETURN;
        END
        
        EXEC maintenance.usp_CreateBackupFolder @DiffDir;
        
        DECLARE @ts NVARCHAR(15) = maintenance.fn_Timestamp_yyyymmdd_hhmm();
        DECLARE @file NVARCHAR(4000) = @DiffDir + N'\Com5600G13_DIFF_' + @ts + N'.dif';
        
        BACKUP DATABASE [Com5600G13]
          TO DISK = @file
          WITH DIFFERENTIAL, INIT, CHECKSUM, STATS = 10;
        
        RESTORE VERIFYONLY FROM DISK = @file WITH CHECKSUM;
        
        PRINT '? BACKUP DIFF completado: ' + @file;
        
        IF OBJECT_ID(N'reportes.Sp_LogReporte', N'P') IS NOT NULL
            EXEC reportes.Sp_LogReporte
                 @Procedimiento = N'maintenance.usp_Backup_Com5600G13_Diff',
                 @Tipo = N'INFO',
                 @Mensaje = N'BACKUP DIFF OK',
                 @Detalle = @file,
                 @RutaArchivo = @file,
                 @RutaLog = @LogFile;
    END TRY
    BEGIN CATCH
        DECLARE @err NVARCHAR(4000) = ERROR_MESSAGE();
        PRINT '? ERROR en BACKUP DIFF: ' + @err;
        
        IF OBJECT_ID(N'reportes.Sp_LogReporte', N'P') IS NOT NULL
            EXEC reportes.Sp_LogReporte
                 @Procedimiento = N'maintenance.usp_Backup_Com5600G13_Diff',
                 @Tipo = N'ERROR',
                 @Mensaje = N'Fallo BACKUP DIFF',
                 @Detalle = @err,
                 @RutaArchivo = NULL,
                 @RutaLog = @LogFile;
        
        THROW;
    END CATCH
END
GO

/* 6) SP: BACKUP LOG (SIN COMPRESSION) */
CREATE PROCEDURE maintenance.usp_Backup_Com5600G13_Log
    @LogDir NVARCHAR(260),
    @LogFile NVARCHAR(260) = NULL
AS
BEGIN
    SET NOCOUNT ON;
    
    BEGIN TRY
        -- Verificar modelo de recuperaci�n FULL
        IF (SELECT recovery_model_desc FROM sys.databases WHERE name = N'Com5600G13') <> 'FULL'
        BEGIN
            PRINT '??  Base no est� en FULL recovery. BACKUP LOG omitido.';
            RETURN;
        END
        
        -- Verificar que existe un FULL previo
        IF NOT EXISTS (
            SELECT 1 FROM msdb.dbo.backupset 
            WHERE database_name = N'Com5600G13' 
              AND type = 'D'
              AND backup_finish_date IS NOT NULL
        )
        BEGIN
            RAISERROR(N'No existe BACKUP FULL previo. Ejecute primero usp_Backup_Com5600G13_Full', 16, 1);
            RETURN;
        END
        
        EXEC maintenance.usp_CreateBackupFolder @LogDir;
        
        DECLARE @ts NVARCHAR(15) = maintenance.fn_Timestamp_yyyymmdd_hhmm();
        DECLARE @file NVARCHAR(4000) = @LogDir + N'\Com5600G13_LOG_' + @ts + N'.trn';
        
        BACKUP LOG [Com5600G13]
          TO DISK = @file
          WITH INIT, CHECKSUM, STATS = 10;
        
        PRINT '? BACKUP LOG completado: ' + @file;
        
        IF OBJECT_ID(N'reportes.Sp_LogReporte', N'P') IS NOT NULL
            EXEC reportes.Sp_LogReporte
                 @Procedimiento = N'maintenance.usp_Backup_Com5600G13_Log',
                 @Tipo = N'INFO',
                 @Mensaje = N'BACKUP LOG OK',
                 @Detalle = @file,
                 @RutaArchivo = @file,
                 @RutaLog = @LogFile;
    END TRY
    BEGIN CATCH
        DECLARE @err NVARCHAR(4000) = ERROR_MESSAGE();
        PRINT '? ERROR en BACKUP LOG: ' + @err;
        
        IF OBJECT_ID(N'reportes.Sp_LogReporte', N'P') IS NOT NULL
            EXEC reportes.Sp_LogReporte
                 @Procedimiento = N'maintenance.usp_Backup_Com5600G13_Log',
                 @Tipo = N'ERROR',
                 @Mensaje = N'Fallo BACKUP LOG',
                 @Detalle = @err,
                 @RutaArchivo = NULL,
                 @RutaLog = @LogFile;
        
        THROW;
    END CATCH
END
GO

PRINT '========================================';
PRINT 'PROCEDIMIENTOS CREADOS EXITOSAMENTE';
PRINT '========================================';
PRINT '';

-- Listar SPs creados
SELECT 
    s.name AS Esquema, 
    p.name AS Procedimiento,
    p.create_date AS Creado
FROM sys.procedures p
JOIN sys.schemas s ON s.schema_id = p.schema_id
WHERE s.name = N'maintenance'
  AND p.name LIKE N'usp_Backup_Com5600G13_%'
ORDER BY p.name;
GO

/* ======================================================
   PASO 1: HABILITAR xp_cmdshell TEMPORALMENTE
   (Para crear carpetas autom�ticamente)
   ====================================================== */
PRINT '';
PRINT '========================================';
PRINT 'CONFIGURANDO xp_cmdshell...';
PRINT '========================================';

EXEC sp_configure 'show advanced options', 1;
RECONFIGURE;
EXEC sp_configure 'xp_cmdshell', 1;
RECONFIGURE;

PRINT '? xp_cmdshell habilitado temporalmente';
GO

/* ======================================================
   PASO 2: EJECUTAR BACKUPS
   ====================================================== */
DECLARE @FullDir NVARCHAR(260) = N'C:\SQLBackups\Com5600G13\Full';
DECLARE @DiffDir NVARCHAR(260) = N'C:\SQLBackups\Com5600G13\Diff';
DECLARE @LogDir  NVARCHAR(260) = N'C:\SQLBackups\Com5600G13\Log';
DECLARE @LogFile NVARCHAR(260) = N'C:\SQLBackups\logs\backups.log';

PRINT '';
PRINT '========================================';
PRINT 'EJECUTANDO BACKUPS...';
PRINT '========================================';

-- FULL (crea carpeta autom�ticamente)
EXEC maintenance.usp_Backup_Com5600G13_Full @FullDir=@FullDir, @LogFile=@LogFile;

-- DIFF (requiere FULL previo)
EXEC maintenance.usp_Backup_Com5600G13_Diff @DiffDir=@DiffDir, @LogFile=@LogFile;

-- LOG (solo si est� en FULL recovery)
EXEC maintenance.usp_Backup_Com5600G13_Log @LogDir=@LogDir, @LogFile=@LogFile;
GO

/* ======================================================
   PASO 3: DESHABILITAR xp_cmdshell (seguridad)
   ====================================================== */
PRINT '';
PRINT '========================================';
PRINT 'DESHABILITANDO xp_cmdshell...';
PRINT '========================================';

EXEC sp_configure 'xp_cmdshell', 0;
RECONFIGURE;
EXEC sp_configure 'show advanced options', 0;
RECONFIGURE;

PRINT '? xp_cmdshell deshabilitado (seguridad)';
GO

/* ======================================================
   VERIFICACI�N FINAL
   ====================================================== */
PRINT '';
PRINT '========================================';
PRINT 'VERIFICACI�N EN MSDB';
PRINT '========================================';

SELECT 
    b.database_name AS BD,
    CASE b.type 
        WHEN 'D' THEN 'FULL' 
        WHEN 'I' THEN 'DIFF' 
        WHEN 'L' THEN 'LOG' 
    END AS Tipo,
    b.backup_start_date AS Inicio,
    b.backup_finish_date AS Fin,
    CAST(b.backup_size / 1024.0 / 1024.0 AS DECIMAL(10,2)) AS TamanioMB,
    b.has_backup_checksums AS ConChecksum,
    mf.physical_device_name AS Archivo
FROM msdb.dbo.backupset b
JOIN msdb.dbo.backupmediafamily mf ON b.media_set_id = mf.media_set_id
WHERE b.database_name = N'Com5600G13'
  AND b.backup_finish_date > DATEADD(MINUTE, -10, GETDATE())
ORDER BY b.backup_finish_date DESC;

PRINT '';
PRINT '========================================';
PRINT 'BACKUPS COMPLETADOS!';
PRINT '========================================';
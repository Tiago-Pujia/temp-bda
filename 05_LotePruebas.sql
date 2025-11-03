USE Com5600G13;
GO

EXEC importacion.Sp_CargarConsorciosDesdeExcel
	@RutaArchivo = N'C:\Users\PC\Desktop\consorcios\datos varios.xlsx',
	@Hoja = N'consorcios$',
	@HDR = 1,
	@LogPath = N'C:\Users\PC\Desktop\consorcios\consorcios.log',
	@Verbose = 1;
GO

EXEC importacion.Sp_CargarGastosDesdeExcel
    @RutaArchivo       = N'C:\Users\PC\Desktop\consorcios\datos varios.xlsx',
    @Hoja              = N'Proveedores$',
    @UsarFechaExpensa  = '1900-01-01',
    @LogPath           = N'C:\Users\PC\Desktop\consorcios\gastos.log',
    @Verbose           = 1;
GO

SELECT * FROM app.Tbl_Gasto_Ordinario;

EXEC importacion.Sp_CargarConsorcioYUF_DesdeCsv
    @RutaArchivo = N'C:\Users\PC\Desktop\consorcios\Inquilino-propietarios-UF.csv',
    @HDR         = 1,
    @LogPath     = N'C:\Users\PC\Desktop\consorcios\uf.log',
    @Verbose     = 1;
GO

EXEC importacion.Sp_CargarUFsDesdeTxt
    @RutaArchivo    = N'C:\Users\PC\Desktop\consorcios\UF por consorcio.txt',
    @HDR            = 1,
    @RowTerminator  = N'0x0d0a',
    @CodePage       = N'65001',
    @LogPath        = N'C:\Users\PC\Desktop\consorcios\ufs_txt.log',
    @Verbose        = 1;
GO

EXEC importacion.Sp_CargarUFInquilinosDesdeCsv
    @RutaArchivo   = N'C:\Users\PC\Desktop\consorcios\Inquilino-propietarios-datos.csv',
    @HDR           = 1,
    @RowTerminator = N'0x0d0a',      -- N'0x0a' si tu CSV es LF
    @CodePage      = N'ACP',         -- si es UTF-8, usá N'65001'
    @LogPath       = N'C:\Users\PC\Desktop\consorcios\uf_inq.log',
    @Verbose       = 1;
GO

EXEC importacion.Sp_CargarGastosDesdeJson
     @RutaArchivo = N'C:\Users\PC\Desktop\consorcios\Servicios.Servicios.json',
     @Anio        = 2025,
     @DiaVto1     = 10,
     @DiaVto2     = 20,
     @LogPath     = N'C:\Users\PC\Desktop\consorcios\gastos_json.log',
     @Verbose     = 1;
GO

EXEC importacion.Sp_CargarPagosDesdeCsv
     @RutaArchivo   = N'C:\Users\PC\Desktop\consorcios\pagos_consorcios.csv',
     @HDR           = 1,
     @Separador     = ',',
     @RowTerminator = N'0x0d0a',   -- si tu CSV es sólo LF, usá N'0x0a'
     @CodePage      = N'65001',    -- si está en ANSI, usá N'ACP'
     @LogPath       = N'C:\Users\PC\Desktop\consorcios\pagos_csv.log',
     @Verbose       = 1;
GO

EXEC app.Sp_CargarGastosExtraordinariosIniciales @Verbose = 1;
GO
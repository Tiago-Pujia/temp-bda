/*
tablas -> Tbl_[NombreTabla] -> ejemplo: Tbl_Usuario
campos -> [nombreCampo] -> ejemplo: idUsuario
vistas -> Vw_[NombreVista]
procedimientos almacenados -> Sp_[NombreProcedimiento]
indices -> IDX_[NombreIndice] -> ejemplo: IDX_Usuario_Email
funciones -> fn_[NombreFuncion]
esquemas -> [nombreEsquema] -> ejemplo: app, importacion, report
rol -> [rol_nombreRol] -> ejemplo: rol_Admin
usuarios -> [usr_nombreUsuario] -> ejemplo: usr_app
*/

/**
PARA BORRAR LA BASE DE DATOS:
USE master;
GO
ALTER DATABASE Com5600G13 SET SINGLE_USER WITH ROLLBACK IMMEDIATE;
DROP DATABASE Com5600G13;
GO
**/

/*
Archivo: 00_Tablas.sql
Propósito: Crea la base de datos Com5600G13 (si no existe), los esquemas y las
tablas principales que usa la aplicación. Contiene constraints básicos y claves
foráneas necesarias para la integridad referencial.

Notas de uso:
 - Ejecutar solo en despliegues controlados o en entornos de desarrollo.
 - Hacer respaldo antes de volver a crear o modificar tablas existentes.
 - No mezclar cambios lógicos con esta pasada de comentarios; este archivo
     inicializa la estructura principal.
*/

USE MASTER
GO

IF NOT EXISTS (SELECT 1 FROM master.dbo.sysdatabases WHERE name = N'Com5600G13')
BEGIN
    EXEC ('CREATE DATABASE Com5600G13 COLLATE Latin1_General_CI_AI;');
END
GO

USE Com5600G13;
GO

/** Este esquema se utilizará para referenciar a los objetos relacionados directamente con los reportes de la aplicación **/
IF NOT EXISTS (SELECT 1 FROM sys.schemas WHERE name = N'reportes') EXEC ('CREATE SCHEMA reportes');

/** Este esquema se utilizará para referenciar a los objetos relacionados directamente con la importación de los archivos **/
IF NOT EXISTS (SELECT 1 FROM sys.schemas WHERE name = N'importacion') EXEC ('CREATE SCHEMA importacion');

/** Este esquema se utilizará para referenciar a los objetos relacionados directamente con la aplicación **/
IF NOT EXISTS (SELECT 1 FROM sys.schemas WHERE name = N'app') EXEC ('CREATE SCHEMA app');

/** Este esquema se utilizará para referenciar a los objetos relacionados directamente con la API **/
IF NOT EXISTS (SELECT 1 FROM sys.schemas WHERE name = N'api') EXEC ('CREATE SCHEMA api');

/** Este esquema se utilizará para referenciar a los objetos relacionados directamente con la seguridad **/
IF NOT EXISTS (SELECT 1 FROM sys.schemas WHERE name = N'seguridad')
    EXEC ('CREATE SCHEMA seguridad');
GO

IF OBJECT_ID(N'app.Tbl_ExpensaEnvio', N'U') IS NOT NULL DROP TABLE app.Tbl_ExpensaEnvio;
IF OBJECT_ID(N'app.Tbl_Pago', N'U') IS NOT NULL DROP TABLE app.Tbl_Pago;
IF OBJECT_ID(N'app.Tbl_EstadoCuenta', N'U') IS NOT NULL DROP TABLE app.Tbl_EstadoCuenta;
IF OBJECT_ID(N'app.Tbl_Gasto_Extraordinario', N'U') IS NOT NULL DROP TABLE app.Tbl_Gasto_Extraordinario;
IF OBJECT_ID(N'app.Tbl_Gasto_Ordinario', N'U') IS NOT NULL DROP TABLE app.Tbl_Gasto_Ordinario;
IF OBJECT_ID(N'app.Tbl_Gasto', N'U') IS NOT NULL DROP TABLE app.Tbl_Gasto;
IF OBJECT_ID(N'app.Tbl_UFPersona', N'U') IS NOT NULL DROP TABLE app.Tbl_UFPersona;
IF OBJECT_ID(N'app.Tbl_UnidadFuncional', N'U') IS NOT NULL DROP TABLE app.Tbl_UnidadFuncional;
IF OBJECT_ID(N'app.Tbl_Expensa', N'U') IS NOT NULL DROP TABLE app.Tbl_Expensa;
IF OBJECT_ID(N'app.Tbl_Persona', N'U') IS NOT NULL DROP TABLE app.Tbl_Persona;
IF OBJECT_ID(N'app.Tbl_Consorcio', N'U') IS NOT NULL DROP TABLE app.Tbl_Consorcio;
IF OBJECT_ID(N'app.Tbl_Feriado', N'U') IS NOT NULL DROP TABLE app.Tbl_Feriado;
IF OBJECT_ID(N'api.Tbl_CotizacionDolar', N'U') IS NOT NULL DROP TABLE api.Tbl_CotizacionDolar;
IF OBJECT_ID(N'reportes.logsReportes', N'U') IS NOT NULL DROP TABLE reportes.logsReportes;
GO

/* ---- Tbl_Persona ---- */
CREATE TABLE app.Tbl_Persona (
    idPersona INT NOT NULL IDENTITY(1,1) PRIMARY KEY,
    nombre VARCHAR(50) NOT NULL,
    apellido VARCHAR(50) NOT NULL,
    dni INT NOT NULL,
    email VARCHAR(100),
    telefono VARCHAR(20),
    CBU_CVU CHAR(22) CHECK (CBU_CVU NOT LIKE '%[^0-9]%'),
    CONSTRAINT CHK_Persona_DNI CHECK (dni > 0 AND dni < 100000000)
);
GO

/* ---- Tbl_Consorcio ---- */
CREATE TABLE app.Tbl_Consorcio (
    idConsorcio INT NOT NULL IDENTITY(1,1) PRIMARY KEY,
    nombre VARCHAR(50) NOT NULL,
    direccion VARCHAR(100),
    superficieTotal DECIMAL(10,2),
    CONSTRAINT CHK_Consorcio_SuperficieTotal CHECK (superficieTotal > 0 OR superficieTotal IS NULL)
);
GO

/* ---- Tbl_UnidadFuncional ---- */
CREATE TABLE app.Tbl_UnidadFuncional (
    idUnidadFuncional INT NOT NULL IDENTITY(1,1),
    idConsorcio INT NOT NULL,
    piso TINYINT,
    departamento CHAR(1),
    superficie DECIMAL(7,2),
    metrosBaulera DECIMAL(5,2),
    metrosCochera DECIMAL(5,2),
    porcentaje DECIMAL(5,2),
    CBU_CVU CHAR(22) CHECK (CBU_CVU NOT LIKE '%[^0-9]%'),
	CONSTRAINT PK_UnidadFuncional
	PRIMARY KEY (idUnidadFuncional, idConsorcio),
    CONSTRAINT FK_UnidadFuncional_Consorcio
        FOREIGN KEY (idConsorcio) REFERENCES app.Tbl_Consorcio (idConsorcio),
    CONSTRAINT CHK_UF_Superficie CHECK (superficie >= 0 OR superficie IS NULL),
    CONSTRAINT CHK_UF_MetrosBaulera CHECK (metrosBaulera >= 0 OR metrosBaulera IS NULL),
    CONSTRAINT CHK_UF_MetrosCochera CHECK (metrosCochera >= 0 OR metrosCochera IS NULL),
    CONSTRAINT CHK_UF_Porcentaje CHECK ((porcentaje > 0 AND porcentaje <= 100) OR porcentaje IS NULL)
);
GO

/* ---- Tbl_UFPersona ---- */
CREATE TABLE app.Tbl_UFPersona (
    idPersona INT NOT NULL,
    idConsorcio INT NOT NULL,
    esInquilino BIT,
    CONSTRAINT PK_UFPersona PRIMARY KEY (idPersona),
    CONSTRAINT FK_UFPersona_Persona
        FOREIGN KEY (idPersona) REFERENCES app.Tbl_Persona (idPersona),
    CONSTRAINT FK_UFPersona_Consorcio
        FOREIGN KEY (idConsorcio) REFERENCES app.Tbl_Consorcio (idConsorcio)
);
GO

/* ---- Tbl_Expensa ---- */
CREATE TABLE app.Tbl_Expensa (
    nroExpensa INT NOT NULL IDENTITY(1,1) PRIMARY KEY,
    idConsorcio INT NOT NULL,
    fechaGeneracion DATE NOT NULL,
    fechaVto1 DATE,
    fechaVto2 DATE,
    montoTotal DECIMAL(10,2),
    CONSTRAINT FK_Expensa_Consorcio
        FOREIGN KEY (idConsorcio) REFERENCES app.Tbl_Consorcio (idConsorcio),
    CONSTRAINT CHK_Expensa_FechaVto1 CHECK (fechaVto1 >= fechaGeneracion OR fechaVto1 IS NULL),
    CONSTRAINT CHK_Expensa_FechaVto2 CHECK (fechaVto2 >= fechaVto1 OR fechaVto2 IS NULL),
    CONSTRAINT CHK_Expensa_MontoTotal CHECK (montoTotal >= 0 OR montoTotal IS NULL)
);
GO

/* ---- Tbl_Gasto ---- */
CREATE TABLE app.Tbl_Gasto (
    idGasto INT NOT NULL IDENTITY(1,1) PRIMARY KEY,
    nroExpensa INT NOT NULL,
    idConsorcio INT NOT NULL,
    tipo VARCHAR(16) CHECK (tipo IN ('Ordinario','Extraordinario')),
    descripcion VARCHAR(200),
    fechaEmision DATE CONSTRAINT DF_Gasto_FechaEmision DEFAULT GETDATE(),
    importe DECIMAL(10,2) CONSTRAINT DF_Gasto_Importe DEFAULT 0,
    CONSTRAINT FK_Gasto_Consorcio
        FOREIGN KEY (idConsorcio) REFERENCES app.Tbl_Consorcio (idConsorcio),
    CONSTRAINT FK_Gasto_Expensa
        FOREIGN KEY (nroExpensa) REFERENCES app.Tbl_Expensa (nroExpensa),
    CONSTRAINT CHK_Gasto_Importe CHECK (importe >= 0)
);
GO

/* ---- Tbl_Gasto_Ordinario ---- */
CREATE TABLE app.Tbl_Gasto_Ordinario (
    idGasto INT NOT NULL PRIMARY KEY,
    nombreProveedor VARCHAR(100),
    categoria VARCHAR(35),
    nroFactura VARCHAR(50),
    CONSTRAINT FK_Ordinario_Gasto
        FOREIGN KEY (idGasto) REFERENCES app.Tbl_Gasto (idGasto)
);
GO

/* ---- Tbl_Gasto_Extraordinario ---- */
CREATE TABLE app.Tbl_Gasto_Extraordinario (
    idGasto INT NOT NULL PRIMARY KEY,
    cuotaActual TINYINT,
    cantCuotas TINYINT,
    CONSTRAINT FK_Extraordinario_Gasto
        FOREIGN KEY (idGasto) REFERENCES app.Tbl_Gasto (idGasto),
    CONSTRAINT CHK_GastoExtra_CuotaActual CHECK (cuotaActual > 0 OR cuotaActual IS NULL),
    CONSTRAINT CHK_GastoExtra_CantCuotas CHECK (cantCuotas > 0 OR cantCuotas IS NULL),
    CONSTRAINT CHK_GastoExtra_Cuotas CHECK (cuotaActual <= cantCuotas OR cuotaActual IS NULL OR cantCuotas IS NULL)
);
GO

/* ---- Tbl_EstadoCuenta ---- */
CREATE TABLE app.Tbl_EstadoCuenta (
    idEstadoCuenta INT NOT NULL IDENTITY(1,1),
    nroUnidadFuncional INT NOT NULL,
    idConsorcio INT NOT NULL,
    nroExpensa INT NOT NULL,
    saldoAnterior DECIMAL(10,2),
    pagoRecibido DECIMAL(10,2),
    deuda DECIMAL(10,2),
    interesMora DECIMAL(6,2),
    expensasOrdinarias DECIMAL(10,2),
    expensasExtraordinarias DECIMAL(10,2),
    totalAPagar DECIMAL(10,2),
    fecha DATE CONSTRAINT DF_EstadoCuenta_Fecha DEFAULT GETDATE(),
    CONSTRAINT PK_EstadoCuenta PRIMARY KEY (idEstadoCuenta, nroUnidadFuncional, idConsorcio),
    CONSTRAINT FK_EstadoCuenta_UF
        FOREIGN KEY (nroUnidadFuncional, idConsorcio)
        REFERENCES app.Tbl_UnidadFuncional (idUnidadFuncional, idConsorcio),
    CONSTRAINT FK_EstadoCuenta_Expensa
        FOREIGN KEY (nroExpensa) REFERENCES app.Tbl_Expensa (nroExpensa),
    CONSTRAINT FK_EstadoCuenta_Consorcio
        FOREIGN KEY (idConsorcio) REFERENCES app.Tbl_Consorcio (idConsorcio),
    CONSTRAINT CHK_EstadoCuenta_InteresMora CHECK (interesMora >= 0 OR interesMora IS NULL)
);
GO

/* ---- Tbl_Pago ---- */
CREATE TABLE app.Tbl_Pago (
    idPago INT NOT NULL IDENTITY(1,1) PRIMARY KEY,
    idEstadoCuenta INT NOT NULL,
    nroUnidadFuncional INT NOT NULL,
    idConsorcio INT NOT NULL,
    nroExpensa INT NOT NULL,
    fecha DATE,
    monto DECIMAL(10,2),
    CBU_CVU CHAR(22) CHECK (CBU_CVU NOT LIKE '%[^0-9]%'),
    CONSTRAINT FK_Pago_EstadoCuenta
        FOREIGN KEY (idEstadoCuenta, nroUnidadFuncional, idConsorcio)
        REFERENCES app.Tbl_EstadoCuenta (idEstadoCuenta, nroUnidadFuncional, idConsorcio),
    CONSTRAINT FK_Pago_Expensa
        FOREIGN KEY (nroExpensa) REFERENCES app.Tbl_Expensa (nroExpensa),
    CONSTRAINT CHK_Pago_Monto CHECK (monto > 0 OR monto IS NULL)
);
GO

/** ---- Tbl_CotizacionDolar ---- **/
CREATE TABLE api.Tbl_CotizacionDolar (
    idCotizacion INT NOT NULL IDENTITY(1,1) PRIMARY KEY,
    fechaConsulta DATETIME2(3) NOT NULL DEFAULT SYSUTCDATETIME(),
    tipoDolar VARCHAR(50) NOT NULL,
    valorCompra DECIMAL(10,2) NOT NULL,
    valorVenta DECIMAL(10,2) NOT NULL,
    CONSTRAINT UQ_CotizacionDolar_FechaTipo 
        UNIQUE (fechaConsulta, tipoDolar)
);
GO

/** ---- logsReportes ---- **/
CREATE TABLE reportes.logsReportes
    (
        idLog INT IDENTITY(1,1) PRIMARY KEY,
        fecha DATETIME2(3) NOT NULL CONSTRAINT DF_logsReportes_fecha DEFAULT SYSUTCDATETIME(),
        procedimiento SYSNAME NULL,
        tipo VARCHAR(30) NOT NULL CHECK (tipo IN ('INFO', 'WARN', 'ERROR')), -- INFO | WARN | ERROR
        mensaje NVARCHAR(4000) NULL,
        detalle NVARCHAR(4000) NULL,
        rutaArchivo NVARCHAR(4000) NULL, -- archivo origen (ej. Excel/CSV)
		rutaLog NVARCHAR(4000) NULL -- path del archivo de log de texto
);
GO

/** ---- Tbl_Feriado ---- **/
CREATE TABLE app.Tbl_Feriado (
    fecha DATE NOT NULL PRIMARY KEY
);
GO

CREATE TABLE app.Tbl_ExpensaEnvio (
        idEnvio        INT IDENTITY(1,1) PRIMARY KEY,
        idConsorcio    INT NOT NULL,
        nroExpensa     INT NOT NULL,
        idPersona      INT NOT NULL,
        medio          VARCHAR(10) NOT NULL CHECK (medio IN ('EMAIL','WHATSAPP','IMPRESO')),
        email          VARCHAR(100) NULL,
        telefono       VARCHAR(20) NULL,
        fechaRegistro  DATETIME2(3) NOT NULL CONSTRAINT DF_Tbl_ExpensaEnvio_fecha DEFAULT SYSUTCDATETIME(),
        observacion    NVARCHAR(200) NULL,
        CONSTRAINT UQ_ExpensaEnvio UNIQUE (idConsorcio, nroExpensa, idPersona),
        CONSTRAINT FK_ExpensaEnvio_Consorcio FOREIGN KEY (idConsorcio) REFERENCES app.Tbl_Consorcio(idConsorcio),
        CONSTRAINT FK_ExpensaEnvio_Expensa   FOREIGN KEY (nroExpensa) REFERENCES app.Tbl_Expensa(nroExpensa),
        CONSTRAINT FK_ExpensaEnvio_Persona   FOREIGN KEY (idPersona)   REFERENCES app.Tbl_Persona(idPersona)
    );
GO
/*
tablas -> Tbl_[NombreTabla] -> ejemplo: Tbl_Usuario
vistas -> Vw_[NombreVista]
procedimientos almacenados -> Sp_[NombreProcedimiento]

campos -> [nombreCampo] -> ejemplo: idUsuario
primary Key -> [NombreTabla] -> ejemplo: Usuario
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
GO

IF OBJECT_ID(N'app.Tbl_Pago', N'U') IS NOT NULL DROP TABLE app.Tbl_Pago;
IF OBJECT_ID(N'app.Tbl_EstadoCuenta', N'U') IS NOT NULL DROP TABLE app.Tbl_EstadoCuenta;
IF OBJECT_ID(N'app.Tbl_Gasto_Extraordinario', N'U') IS NOT NULL DROP TABLE app.Tbl_Gasto_Extraordinario;
IF OBJECT_ID(N'app.Tbl_Gasto_Ordinario', N'U') IS NOT NULL DROP TABLE app.Tbl_Gasto_Ordinario;
IF OBJECT_ID(N'app.Tbl_Gasto', N'U') IS NOT NULL DROP TABLE app.Tbl_Gasto;
IF OBJECT_ID(N'app.Tbl_Expensa', N'U') IS NOT NULL DROP TABLE app.Tbl_Expensa;
IF OBJECT_ID(N'app.Tbl_UFPersona', N'U') IS NOT NULL DROP TABLE app.Tbl_UFPersona;
IF OBJECT_ID(N'app.Tbl_UnidadFuncional', N'U') IS NOT NULL DROP TABLE app.Tbl_UnidadFuncional;
IF OBJECT_ID(N'app.Tbl_Consorcio', N'U') IS NOT NULL DROP TABLE app.Tbl_Consorcio;
IF OBJECT_ID(N'app.Tbl_Persona', N'U') IS NOT NULL DROP TABLE app.Tbl_Persona;
GO

/* ---- Tbl_Persona ---- */
CREATE TABLE app.Tbl_Persona (
    idPersona INT NOT NULL IDENTITY(1,1) PRIMARY KEY,
    nombre VARCHAR(50) NOT NULL,
    apellido VARCHAR(50) NOT NULL,
    dni INT NOT NULL,
    email VARCHAR(100) UNIQUE,
    telefono VARCHAR(12),
    CBU_CVU CHAR(22) UNIQUE
);
GO

/* ---- Tbl_Consorcio ---- */
CREATE TABLE app.Tbl_Consorcio (
    idConsorcio INT NOT NULL IDENTITY(1,1) PRIMARY KEY,
    nombre VARCHAR(50) NOT NULL,
    direccion VARCHAR(100),
    superficieTotal  DECIMAL(10,2)
);
GO

/* ---- Tbl_UnidadFuncional ---- */
CREATE TABLE app.Tbl_UnidadFuncional (
    idUnidadFuncional INT NOT NULL IDENTITY(1,1) PRIMARY KEY,
    idConsorcio INT NOT NULL,
    piso TINYINT,
    departamento CHAR(1),
    superficie DECIMAL(7,2), -- superficie de la UF
    metrosBaulera DECIMAL(5,2), -- 0 => sin baulera
    metrosCochera DECIMAL(5,2), -- 0 => sin cochera
    porcentaje DECIMAL(5,2),
    CONSTRAINT FK_UnidadFuncional_Consorcio
        FOREIGN KEY (idConsorcio) REFERENCES app.Tbl_Consorcio (idConsorcio)
);
GO

/* ---- Tbl_UFPersona ---- */
CREATE TABLE app.Tbl_UFPersona (
    idPersona INT NOT NULL,
    idUnidadFuncional INT NOT NULL,
    idConsorcio INT NOT NULL,
    esInquilino BIT,
    fechaInicio DATE,
    fechaFin DATE,
    CONSTRAINT PK_UFPersona PRIMARY KEY (idPersona, idUnidadFuncional),
    CONSTRAINT FK_UFPersona_Persona
        FOREIGN KEY (idPersona) REFERENCES app.Tbl_Persona (idPersona),
    CONSTRAINT FK_UFPersona_UF
        FOREIGN KEY (idUnidadFuncional) REFERENCES app.Tbl_UnidadFuncional (idUnidadFuncional),
    CONSTRAINT FK_UFPersona_Consorcio
        FOREIGN KEY (idConsorcio) REFERENCES app.Tbl_Consorcio (idConsorcio)
);
GO

/* ---- Tbl_Expensa ---- */
CREATE TABLE app.Tbl_Expensa (
    nroExpensa INT NOT NULL IDENTITY(1,1) PRIMARY KEY,
    idConsorcio INT NOT NULL,
    fechaGeneracion DATE,
    fechaVto1 DATE,
    fechaVto2 DATE,
    montoTotal DECIMAL(10,2),
    CONSTRAINT FK_Expensa_Consorcio
        FOREIGN KEY (idConsorcio) REFERENCES app.Tbl_Consorcio (idConsorcio)
);
GO

/* ---- Tbl_Gasto ---- */
CREATE TABLE app.Tbl_Gasto (
    idGasto INT NOT NULL IDENTITY(1,1) PRIMARY KEY,
    nroExpensa INT NOT NULL,
    idConsorcio INT NOT NULL,
    tipo VARCHAR(16) CHECK (tipo IN ('Ordinario','Extraordinario')),
    descripcion VARCHAR(200),
    fechaEmision DATE,
    importe DECIMAL(10,2),
    CONSTRAINT FK_Gasto_Consorcio
        FOREIGN KEY (idConsorcio) REFERENCES app.Tbl_Consorcio (idConsorcio),
    CONSTRAINT FK_Gasto_Expensa
        FOREIGN KEY (nroExpensa) REFERENCES app.Tbl_Expensa (nroExpensa)
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
        FOREIGN KEY (idGasto) REFERENCES app.Tbl_Gasto (idGasto)
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
    fecha DATE,
    CONSTRAINT PK_EstadoCuenta PRIMARY KEY (idEstadoCuenta, nroUnidadFuncional, idConsorcio),
    CONSTRAINT FK_EstadoCuenta_UF
        FOREIGN KEY (nroUnidadFuncional) REFERENCES app.Tbl_UnidadFuncional (idUnidadFuncional),
    CONSTRAINT FK_EstadoCuenta_Expensa
        FOREIGN KEY (nroExpensa) REFERENCES app.Tbl_Expensa (nroExpensa),
    CONSTRAINT FK_EstadoCuenta_Consorcio
        FOREIGN KEY (idConsorcio) REFERENCES app.Tbl_Consorcio (idConsorcio)
);

/* ---- Tbl_Pago ---- */
CREATE TABLE app.Tbl_Pago (
    idPago INT NOT NULL IDENTITY(1,1) PRIMARY KEY,
    idEstadoCuenta INT NOT NULL,
    nroUnidadFuncional INT NOT NULL,
    idConsorcio INT NOT NULL,
    nroExpensa INT NOT NULL,
    fecha  DATE,
    monto DECIMAL(10,2),
    CBU_CVU VARCHAR(22),
    CONSTRAINT FK_Pago_EstadoCuenta
        FOREIGN KEY (idEstadoCuenta, nroUnidadFuncional, idConsorcio)
        REFERENCES app.Tbl_EstadoCuenta (idEstadoCuenta, nroUnidadFuncional, idConsorcio),
    CONSTRAINT FK_Pago_Expensa
        FOREIGN KEY (nroExpensa) REFERENCES app.Tbl_Expensa (nroExpensa)
);
GO
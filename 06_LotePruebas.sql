USE Com5600G13;
GO

/* =========================================================
   1. CONSORCIOS DE PRUEBA
   ========================================================= */

DECLARE @idConsFullBC INT;       -- Consorcio con baulera y cochera
DECLARE @idConsSinBC INT;        -- Consorcio sin baulera ni cochera
DECLARE @idConsSoloBaulera INT;  -- Consorcio solo baulera
DECLARE @idConsSoloCochera INT;  -- Consorcio solo cochera

-- Consorcio 1: con baulera y cochera
IF NOT EXISTS (SELECT 1 FROM app.Tbl_Consorcio WHERE nombre = 'CONSORCIO_TEST_1_FULL_BC')
BEGIN
    INSERT INTO app.Tbl_Consorcio (nombre, direccion, superficieTotal)
    VALUES ('CONSORCIO_TEST_1_FULL_BC', 'Altos Saint Just 100', 1000.00);
END;
SELECT @idConsFullBC = idConsorcio
FROM app.Tbl_Consorcio
WHERE nombre = 'CONSORCIO_TEST_1_FULL_BC';

-- Consorcio 2: sin baulera ni cochera
IF NOT EXISTS (SELECT 1 FROM app.Tbl_Consorcio WHERE nombre = 'CONSORCIO_TEST_2_SIN_BC')
BEGIN
    INSERT INTO app.Tbl_Consorcio (nombre, direccion, superficieTotal)
    VALUES ('CONSORCIO_TEST_2_SIN_BC', 'Calle Falsa 456', 800.00);
END;
SELECT @idConsSinBC = idConsorcio
FROM app.Tbl_Consorcio
WHERE nombre = 'CONSORCIO_TEST_2_SIN_BC';

-- Consorcio 3: solo baulera
IF NOT EXISTS (SELECT 1 FROM app.Tbl_Consorcio WHERE nombre = 'CONSORCIO_TEST_3_SOLO_BAULERA')
BEGIN
    INSERT INTO app.Tbl_Consorcio (nombre, direccion, superficieTotal)
    VALUES ('CONSORCIO_TEST_3_SOLO_BAULERA', 'Pasaje Prueba 789', 600.00);
END;
SELECT @idConsSoloBaulera = idConsorcio
FROM app.Tbl_Consorcio
WHERE nombre = 'CONSORCIO_TEST_3_SOLO_BAULERA';

-- Consorcio 4: solo cochera
IF NOT EXISTS (SELECT 1 FROM app.Tbl_Consorcio WHERE nombre = 'CONSORCIO_TEST_4_SOLO_COCHERA')
BEGIN
    INSERT INTO app.Tbl_Consorcio (nombre, direccion, superficieTotal)
    VALUES ('CONSORCIO_TEST_4_SOLO_COCHERA', 'Boulevard Test 101', 900.00);
END;
SELECT @idConsSoloCochera = idConsorcio
FROM app.Tbl_Consorcio
WHERE nombre = 'CONSORCIO_TEST_4_SOLO_COCHERA';


/* =========================================================
   2. PERSONAS Y RELACI�N CON CONSORCIOS (PROPIETARIOS / INQUILINOS)
   ========================================================= */

DECLARE @idPerJose   INT;
DECLARE @idPerMaria  INT;
DECLARE @idPerCarlos INT;
DECLARE @idPerAna    INT;
DECLARE @idPerLucia  INT;
DECLARE @idPerDiego  INT;

-- Jos� Gimenez - propietario consorcio 1 (con email)
IF NOT EXISTS (SELECT 1 FROM app.Tbl_Persona WHERE dni = 10000001)
BEGIN
    INSERT INTO app.Tbl_Persona (nombre, apellido, dni, email, telefono, CBU_CVU)
    VALUES ('Jose', 'Gimenez', 10000001, 'jose.gimenez@example.com', '1140000001', '0000000000000000010001');
END;
SELECT @idPerJose = idPersona FROM app.Tbl_Persona WHERE dni = 10000001;

-- Maria Lopez - propietaria consorcio 2 (SIN email -> se testea whatsapp / copia impresa)
IF NOT EXISTS (SELECT 1 FROM app.Tbl_Persona WHERE dni = 10000002)
BEGIN
    INSERT INTO app.Tbl_Persona (nombre, apellido, dni, email, telefono, CBU_CVU)
    VALUES ('Maria', 'Lopez', 10000002, NULL, '1140000002', '0000000000000000010002');
END;
SELECT @idPerMaria = idPersona FROM app.Tbl_Persona WHERE dni = 10000002;

-- Carlos Perez - propietario consorcio 3
IF NOT EXISTS (SELECT 1 FROM app.Tbl_Persona WHERE dni = 10000003)
BEGIN
    INSERT INTO app.Tbl_Persona (nombre, apellido, dni, email, telefono, CBU_CVU)
    VALUES ('Carlos', 'Perez', 10000003, 'carlos.perez@example.com', '1140000003', '0000000000000000010003');
END;
SELECT @idPerCarlos = idPersona FROM app.Tbl_Persona WHERE dni = 10000003;

-- Ana Diaz - propietaria consorcio 4
IF NOT EXISTS (SELECT 1 FROM app.Tbl_Persona WHERE dni = 10000004)
BEGIN
    INSERT INTO app.Tbl_Persona (nombre, apellido, dni, email, telefono, CBU_CVU)
    VALUES ('Ana', 'Diaz', 10000004, 'ana.diaz@example.com', '1140000004', '0000000000000000010004');
END;
SELECT @idPerAna = idPersona FROM app.Tbl_Persona WHERE dni = 10000004;

-- Lucia Romero - inquilina consorcio 1
IF NOT EXISTS (SELECT 1 FROM app.Tbl_Persona WHERE dni = 10000005)
BEGIN
    INSERT INTO app.Tbl_Persona (nombre, apellido, dni, email, telefono, CBU_CVU)
    VALUES ('Lucia', 'Romero', 10000005, 'lucia.romero@example.com', '1140000005', '0000000000000000010005');
END;
SELECT @idPerLucia = idPersona FROM app.Tbl_Persona WHERE dni = 10000005;

-- Diego Fernandez - inquilino consorcio 2
IF NOT EXISTS (SELECT 1 FROM app.Tbl_Persona WHERE dni = 10000006)
BEGIN
    INSERT INTO app.Tbl_Persona (nombre, apellido, dni, email, telefono, CBU_CVU)
    VALUES ('Diego', 'Fernandez', 10000006, 'diego.fernandez@example.com', '1140000006', '0000000000000000010006');
END;
SELECT @idPerDiego = idPersona FROM app.Tbl_Persona WHERE dni = 10000006;

-- Relaci�n UFPersona (a nivel consorcio)
IF NOT EXISTS (SELECT 1 FROM app.Tbl_UFPersona WHERE idPersona = @idPerJose)
BEGIN
    INSERT INTO app.Tbl_UFPersona (idPersona, idConsorcio, esInquilino, fechaInicio, fechaFin)
    VALUES (@idPerJose, @idConsFullBC, 0, '2025-01-01', NULL);
END;

IF NOT EXISTS (SELECT 1 FROM app.Tbl_UFPersona WHERE idPersona = @idPerMaria)
BEGIN
    INSERT INTO app.Tbl_UFPersona (idPersona, idConsorcio, esInquilino, fechaInicio, fechaFin)
    VALUES (@idPerMaria, @idConsSinBC, 0, '2025-01-01', NULL);
END;

IF NOT EXISTS (SELECT 1 FROM app.Tbl_UFPersona WHERE idPersona = @idPerCarlos)
BEGIN
    INSERT INTO app.Tbl_UFPersona (idPersona, idConsorcio, esInquilino, fechaInicio, fechaFin)
    VALUES (@idPerCarlos, @idConsSoloBaulera, 0, '2025-01-01', NULL);
END;

IF NOT EXISTS (SELECT 1 FROM app.Tbl_UFPersona WHERE idPersona = @idPerAna)
BEGIN
    INSERT INTO app.Tbl_UFPersona (idPersona, idConsorcio, esInquilino, fechaInicio, fechaFin)
    VALUES (@idPerAna, @idConsSoloCochera, 0, '2025-01-01', NULL);
END;

IF NOT EXISTS (SELECT 1 FROM app.Tbl_UFPersona WHERE idPersona = @idPerLucia)
BEGIN
    INSERT INTO app.Tbl_UFPersona (idPersona, idConsorcio, esInquilino, fechaInicio, fechaFin)
    VALUES (@idPerLucia, @idConsFullBC, 1, '2025-02-01', NULL);
END;

IF NOT EXISTS (SELECT 1 FROM app.Tbl_UFPersona WHERE idPersona = @idPerDiego)
BEGIN
    INSERT INTO app.Tbl_UFPersona (idPersona, idConsorcio, esInquilino, fechaInicio, fechaFin)
    VALUES (@idPerDiego, @idConsSinBC, 1, '2025-02-01', NULL);
END;


/* =========================================================
   3. UNIDADES FUNCIONALES (10 por consorcio)
   - Se usan CBU_CVU 0000000000000000000001 a 0000000000000000000040
   - Consorcio 1: mezcla de metrosBaulera y metrosCochera (>0 ambos, etc.)
   - Consorcio 2: sin baulera ni cochera (0,0)
   - Consorcio 3: solo baulera (>0, 0)
   - Consorcio 4: solo cochera (0, >0)
   ========================================================= */

DECLARE @i INT;

-- Helper para armar CBU_CVU (vamos a escribirlos literal para evitar errores)

-- Consorcio 1: FULL (UF 1-10 => CBU 1-10)
IF NOT EXISTS (SELECT 1 FROM app.Tbl_UnidadFuncional WHERE idConsorcio = @idConsFullBC)
BEGIN
    INSERT INTO app.Tbl_UnidadFuncional (idConsorcio, piso, departamento, superficie, metrosBaulera, metrosCochera, porcentaje, CBU_CVU)
    VALUES 
      (@idConsFullBC, 0, 'A',  40.00,  6.00, 12.00,  4.00, '0000000000000000000001'),
      (@idConsFullBC, 0, 'B',  60.00,  0.00, 10.00,  6.00, '0000000000000000000002'),
      (@idConsFullBC, 0, 'C',  80.00,  6.00,  0.00,  8.00, '0000000000000000000003'),
      (@idConsFullBC, 1, 'A', 120.00,  0.00, 15.00, 12.00, '0000000000000000000004'),
      (@idConsFullBC, 1, 'B', 100.00,  6.00,  0.00, 10.00, '0000000000000000000005'),
      (@idConsFullBC, 2, 'A',  90.00,  0.00, 12.00,  9.00, '0000000000000000000006'),
      (@idConsFullBC, 2, 'B', 110.00,  8.00,  0.00, 11.00, '0000000000000000000007'),
      (@idConsFullBC, 3, 'A', 130.00,  0.00, 16.00, 13.00, '0000000000000000000008'),
      (@idConsFullBC, 3, 'B', 140.00, 10.00,  0.00, 14.00, '0000000000000000000009'),
      (@idConsFullBC, 3, 'C', 130.00,  0.00, 18.00, 13.00, '0000000000000000000010');
END;

-- Consorcio 2: SIN BAULERA NI COCHERA (UF 11-20)
IF NOT EXISTS (SELECT 1 FROM app.Tbl_UnidadFuncional WHERE idConsorcio = @idConsSinBC)
BEGIN
    INSERT INTO app.Tbl_UnidadFuncional (idConsorcio, piso, departamento, superficie, metrosBaulera, metrosCochera, porcentaje, CBU_CVU)
    VALUES 
      (@idConsSinBC, 0, 'A',  40.00,  0.00, 0.00,  5.00, '0000000000000000000011'),
      (@idConsSinBC, 0, 'B',  60.00,  0.00, 0.00,  7.00, '0000000000000000000012'),
      (@idConsSinBC, 0, 'C',  80.00,  0.00, 0.00, 10.00, '0000000000000000000013'),
      (@idConsSinBC, 1, 'A',  90.00,  0.00, 0.00, 11.00, '0000000000000000000014'),
      (@idConsSinBC, 1, 'B', 100.00,  0.00, 0.00, 12.00, '0000000000000000000015'),
      (@idConsSinBC, 2, 'A',  70.00,  0.00, 0.00,  9.00, '0000000000000000000016'),
      (@idConsSinBC, 2, 'B',  70.00,  0.00, 0.00,  9.00, '0000000000000000000017'),
      (@idConsSinBC, 3, 'A', 110.00,  0.00, 0.00, 14.00, '0000000000000000000018'),
      (@idConsSinBC, 3, 'B', 110.00,  0.00, 0.00, 14.00, '0000000000000000000019'),
      (@idConsSinBC, 3, 'C',  70.00,  0.00, 0.00,  9.00, '0000000000000000000020');
END;

-- Consorcio 3: SOLO BAULERA (UF 21-30, metrosBaulera > 0, metrosCochera = 0)
IF NOT EXISTS (SELECT 1 FROM app.Tbl_UnidadFuncional WHERE idConsorcio = @idConsSoloBaulera)
BEGIN
    INSERT INTO app.Tbl_UnidadFuncional (idConsorcio, piso, departamento, superficie, metrosBaulera, metrosCochera, porcentaje, CBU_CVU)
    VALUES 
      (@idConsSoloBaulera, 0, 'A',  40.00,  5.00, 0.00,  7.00, '0000000000000000000021'),
      (@idConsSoloBaulera, 0, 'B',  60.00,  5.00, 0.00, 10.00, '0000000000000000000022'),
      (@idConsSoloBaulera, 0, 'C',  80.00,  7.00, 0.00, 13.00, '0000000000000000000023'),
      (@idConsSoloBaulera, 1, 'A',  70.00,  6.00, 0.00, 11.00, '0000000000000000000024'),
      (@idConsSoloBaulera, 1, 'B',  60.00,  5.00, 0.00, 10.00, '0000000000000000000025'),
      (@idConsSoloBaulera, 2, 'A',  60.00,  5.00, 0.00, 10.00, '0000000000000000000026'),
      (@idConsSoloBaulera, 2, 'B',  60.00,  5.00, 0.00, 10.00, '0000000000000000000027'),
      (@idConsSoloBaulera, 3, 'A',  70.00,  6.00, 0.00, 11.00, '0000000000000000000028'),
      (@idConsSoloBaulera, 3, 'B',  50.00,  4.00, 0.00,  8.00, '0000000000000000000029'),
      (@idConsSoloBaulera, 3, 'C',  50.00,  4.00, 0.00,  8.00, '0000000000000000000030');
END;

-- Consorcio 4: SOLO COCHERA (UF 31-40, metrosBaulera = 0, metrosCochera > 0)
IF NOT EXISTS (SELECT 1 FROM app.Tbl_UnidadFuncional WHERE idConsorcio = @idConsSoloCochera)
BEGIN
    INSERT INTO app.Tbl_UnidadFuncional (idConsorcio, piso, departamento, superficie, metrosBaulera, metrosCochera, porcentaje, CBU_CVU)
    VALUES 
      (@idConsSoloCochera, 0, 'A',  40.00, 0.00, 10.00,  7.00, '0000000000000000000031'),
      (@idConsSoloCochera, 0, 'B',  60.00, 0.00, 12.00, 10.00, '0000000000000000000032'),
      (@idConsSoloCochera, 0, 'C',  80.00, 0.00, 15.00, 13.00, '0000000000000000000033'),
      (@idConsSoloCochera, 1, 'A',  70.00, 0.00, 12.00, 11.00, '0000000000000000000034'),
      (@idConsSoloCochera, 1, 'B',  60.00, 0.00, 10.00, 10.00, '0000000000000000000035'),
      (@idConsSoloCochera, 2, 'A',  60.00, 0.00, 10.00, 10.00, '0000000000000000000036'),
      (@idConsSoloCochera, 2, 'B',  60.00, 0.00, 10.00, 10.00, '0000000000000000000037'),
      (@idConsSoloCochera, 3, 'A',  70.00, 0.00, 12.00, 11.00, '0000000000000000000038'),
      (@idConsSoloCochera, 3, 'B',  50.00, 0.00,  8.00,  8.00, '0000000000000000000039'),
      (@idConsSoloCochera, 3, 'C',  50.00, 0.00,  8.00,  8.00, '0000000000000000000040');
END;


/* =========================================================
   4. EXPENSAS (3 meses) PARA CONSORCIO 1 (FULL_BC)
   - Enero 2025: solo ordinarias
   - Febrero 2025: solo ordinarias
   - Marzo 2025: ordinarias + extraordinarias
   ========================================================= */

DECLARE @ExpEne2025_C1 INT;
DECLARE @ExpFeb2025_C1 INT;
DECLARE @ExpMar2025_C1 INT;

-- Enero 2025
IF NOT EXISTS (SELECT 1 FROM app.Tbl_Expensa WHERE idConsorcio = @idConsFullBC AND fechaGeneracion = '2025-01-07')
BEGIN
    INSERT INTO app.Tbl_Expensa (idConsorcio, fechaGeneracion, fechaVto1, fechaVto2, montoTotal)
    VALUES (@idConsFullBC, '2025-01-07', '2025-01-15', '2025-01-25', 500000.00);
END;
SELECT @ExpEne2025_C1 = nroExpensa
FROM app.Tbl_Expensa
WHERE idConsorcio = @idConsFullBC AND fechaGeneracion = '2025-01-07';

-- Febrero 2025
IF NOT EXISTS (SELECT 1 FROM app.Tbl_Expensa WHERE idConsorcio = @idConsFullBC AND fechaGeneracion = '2025-02-07')
BEGIN
    INSERT INTO app.Tbl_Expensa (idConsorcio, fechaGeneracion, fechaVto1, fechaVto2, montoTotal)
    VALUES (@idConsFullBC, '2025-02-07', '2025-02-15', '2025-02-25', 520000.00);
END;
SELECT @ExpFeb2025_C1 = nroExpensa
FROM app.Tbl_Expensa
WHERE idConsorcio = @idConsFullBC AND fechaGeneracion = '2025-02-07';

-- Marzo 2025 (con extraordinarias)
IF NOT EXISTS (SELECT 1 FROM app.Tbl_Expensa WHERE idConsorcio = @idConsFullBC AND fechaGeneracion = '2025-03-07')
BEGIN
    INSERT INTO app.Tbl_Expensa (idConsorcio, fechaGeneracion, fechaVto1, fechaVto2, montoTotal)
    VALUES (@idConsFullBC, '2025-03-07', '2025-03-15', '2025-03-25', 600000.00);
END;
SELECT @ExpMar2025_C1 = nroExpensa
FROM app.Tbl_Expensa
WHERE idConsorcio = @idConsFullBC AND fechaGeneracion = '2025-03-07';


/* =========================================================
   5. GASTOS ORDINARIOS Y EXTRAORDINARIOS (Consorcio 1)
   ========================================================= */

DECLARE @idGasto INT;

-- ========== ENERO 2025: GASTOS ORDINARIOS ==========

-- 1) Mantenimiento cuenta bancaria
SELECT @idGasto = idGasto
FROM app.Tbl_Gasto
WHERE idConsorcio = @idConsFullBC AND nroExpensa = @ExpEne2025_C1
  AND descripcion = 'Mantenimiento cuenta bancaria - Enero 2025';

IF @idGasto IS NULL
BEGIN
    INSERT INTO app.Tbl_Gasto (nroExpensa, idConsorcio, tipo, descripcion, fechaEmision, importe)
    VALUES (@ExpEne2025_C1, @idConsFullBC, 'Ordinario',
            'Mantenimiento cuenta bancaria - Enero 2025', '2025-01-05', 1500.00);
    SET @idGasto = SCOPE_IDENTITY();
END;

IF NOT EXISTS (SELECT 1 FROM app.Tbl_Gasto_Ordinario WHERE idGasto = @idGasto)
BEGIN
    INSERT INTO app.Tbl_Gasto_Ordinario (idGasto, nombreProveedor, categoria, nroFactura)
    VALUES (@idGasto, 'Banco Prueba S.A.', 'Mantenimiento Cuenta', 'FAC-BCO-EN-2025-0001');
END;

-- 2) Limpieza - Opci�n 1: sueldo + productos
-- 2.a) Sueldo empleado servicio dom�stico
SELECT @idGasto = idGasto
FROM app.Tbl_Gasto
WHERE idConsorcio = @idConsFullBC AND nroExpensa = @ExpEne2025_C1
  AND descripcion = 'Sueldo empleado de limpieza - Enero 2025';

IF @idGasto IS NULL
BEGIN
    INSERT INTO app.Tbl_Gasto (nroExpensa, idConsorcio, tipo, descripcion, fechaEmision, importe)
    VALUES (@ExpEne2025_C1, @idConsFullBC, 'Ordinario',
            'Sueldo empleado de limpieza - Enero 2025', '2025-01-02', 80000.00);
    SET @idGasto = SCOPE_IDENTITY();
END;

IF NOT EXISTS (SELECT 1 FROM app.Tbl_Gasto_Ordinario WHERE idGasto = @idGasto)
BEGIN
    INSERT INTO app.Tbl_Gasto_Ordinario (idGasto, nombreProveedor, categoria, nroFactura)
    VALUES (@idGasto, 'Empleado limpieza', 'Limpieza - Sueldo', 'RECIBO-EMP-EN-2025-0001');
END;

-- 2.b) Productos de limpieza
SELECT @idGasto = idGasto
FROM app.Tbl_Gasto
WHERE idConsorcio = @idConsFullBC AND nroExpensa = @ExpEne2025_C1
  AND descripcion = 'Productos de limpieza - Enero 2025';

IF @idGasto IS NULL
BEGIN
    INSERT INTO app.Tbl_Gasto (nroExpensa, idConsorcio, tipo, descripcion, fechaEmision, importe)
    VALUES (@ExpEne2025_C1, @idConsFullBC, 'Ordinario',
            'Productos de limpieza - Enero 2025', '2025-01-03', 15000.00);
    SET @idGasto = SCOPE_IDENTITY();
END;

IF NOT EXISTS (SELECT 1 FROM app.Tbl_Gasto_Ordinario WHERE idGasto = @idGasto)
BEGIN
    INSERT INTO app.Tbl_Gasto_Ordinario (idGasto, nombreProveedor, categoria, nroFactura)
    VALUES (@idGasto, 'Limpio S.R.L.', 'Limpieza - Productos', 'FAC-LIMP-EN-2025-0001');
END;

-- 3) Honorarios administraci�n
SELECT @idGasto = idGasto
FROM app.Tbl_Gasto
WHERE idConsorcio = @idConsFullBC AND nroExpensa = @ExpEne2025_C1
  AND descripcion = 'Honorarios administraci�n - Enero 2025';

IF @idGasto IS NULL
BEGIN
    INSERT INTO app.Tbl_Gasto (nroExpensa, idConsorcio, tipo, descripcion, fechaEmision, importe)
    VALUES (@ExpEne2025_C1, @idConsFullBC, 'Ordinario',
            'Honorarios administraci�n - Enero 2025', '2025-01-04', 60000.00);
    SET @idGasto = SCOPE_IDENTITY();
END;

IF NOT EXISTS (SELECT 1 FROM app.Tbl_Gasto_Ordinario WHERE idGasto = @idGasto)
BEGIN
    INSERT INTO app.Tbl_Gasto_Ordinario (idGasto, nombreProveedor, categoria, nroFactura)
    VALUES (@idGasto, 'Administraci�n Altos SJ', 'Honorarios', 'FAC-ADM-EN-2025-0001');
END;

-- 4) Seguros
SELECT @idGasto = idGasto
FROM app.Tbl_Gasto
WHERE idConsorcio = @idConsFullBC AND nroExpensa = @ExpEne2025_C1
  AND descripcion = 'Seguro integral consorcio - Enero 2025';

IF @idGasto IS NULL
BEGIN
    INSERT INTO app.Tbl_Gasto (nroExpensa, idConsorcio, tipo, descripcion, fechaEmision, importe)
    VALUES (@ExpEne2025_C1, @idConsFullBC, 'Ordinario',
            'Seguro integral consorcio - Enero 2025', '2025-01-05', 30000.00);
    SET @idGasto = SCOPE_IDENTITY();
END;

IF NOT EXISTS (SELECT 1 FROM app.Tbl_Gasto_Ordinario WHERE idGasto = @idGasto)
BEGIN
    INSERT INTO app.Tbl_Gasto_Ordinario (idGasto, nombreProveedor, categoria, nroFactura)
    VALUES (@idGasto, 'Seguros Unidos S.A.', 'Seguros', 'FAC-SEG-EN-2025-0001');
END;

-- 5) Gastos generales (ej: fumigaci�n, limpieza de tanques)
SELECT @idGasto = idGasto
FROM app.Tbl_Gasto
WHERE idConsorcio = @idConsFullBC AND nroExpensa = @ExpEne2025_C1
  AND descripcion = 'Fumigaci�n mensual - Enero 2025';

IF @idGasto IS NULL
BEGIN
    INSERT INTO app.Tbl_Gasto (nroExpensa, idConsorcio, tipo, descripcion, fechaEmision, importe)
    VALUES (@ExpEne2025_C1, @idConsFullBC, 'Ordinario',
            'Fumigaci�n mensual - Enero 2025', '2025-01-06', 10000.00);
    SET @idGasto = SCOPE_IDENTITY();
END;

IF NOT EXISTS (SELECT 1 FROM app.Tbl_Gasto_Ordinario WHERE idGasto = @idGasto)
BEGIN
    INSERT INTO app.Tbl_Gasto_Ordinario (idGasto, nombreProveedor, categoria, nroFactura)
    VALUES (@idGasto, 'FumiControl S.R.L.', 'Gastos Generales', 'FAC-FUM-EN-2025-0001');
END;

SELECT @idGasto = idGasto
FROM app.Tbl_Gasto
WHERE idConsorcio = @idConsFullBC AND nroExpensa = @ExpEne2025_C1
  AND descripcion = 'Limpieza de tanques de agua - Enero 2025';

IF @idGasto IS NULL
BEGIN
    INSERT INTO app.Tbl_Gasto (nroExpensa, idConsorcio, tipo, descripcion, fechaEmision, importe)
    VALUES (@ExpEne2025_C1, @idConsFullBC, 'Ordinario',
            'Limpieza de tanques de agua - Enero 2025', '2025-01-08', 20000.00);
    SET @idGasto = SCOPE_IDENTITY();
END;

IF NOT EXISTS (SELECT 1 FROM app.Tbl_Gasto_Ordinario WHERE idGasto = @idGasto)
BEGIN
    INSERT INTO app.Tbl_Gasto_Ordinario (idGasto, nombreProveedor, categoria, nroFactura)
    VALUES (@idGasto, 'Agua Limpia S.A.', 'Gastos Generales', 'FAC-TAN-EN-2025-0001');
END;

-- 6) Servicios p�blicos: Luz, Agua, Internet
-- Luz
SELECT @idGasto = idGasto
FROM app.Tbl_Gasto
WHERE idConsorcio = @idConsFullBC AND nroExpensa = @ExpEne2025_C1
  AND descripcion = 'Servicio de Luz - Enero 2025';

IF @idGasto IS NULL
BEGIN
    INSERT INTO app.Tbl_Gasto (nroExpensa, idConsorcio, tipo, descripcion, fechaEmision, importe)
    VALUES (@ExpEne2025_C1, @idConsFullBC, 'Ordinario',
            'Servicio de Luz - Enero 2025', '2025-01-10', 25000.00);
    SET @idGasto = SCOPE_IDENTITY();
END;

IF NOT EXISTS (SELECT 1 FROM app.Tbl_Gasto_Ordinario WHERE idGasto = @idGasto)
BEGIN
    INSERT INTO app.Tbl_Gasto_Ordinario (idGasto, nombreProveedor, categoria, nroFactura)
    VALUES (@idGasto, 'Edesur', 'Servicios P�blicos - Luz', 'FAC-LUZ-EN-2025-0001');
END;

-- Agua
SELECT @idGasto = idGasto
FROM app.Tbl_Gasto
WHERE idConsorcio = @idConsFullBC AND nroExpensa = @ExpEne2025_C1
  AND descripcion = 'Servicio de Agua - Enero 2025';

IF @idGasto IS NULL
BEGIN
    INSERT INTO app.Tbl_Gasto (nroExpensa, idConsorcio, tipo, descripcion, fechaEmision, importe)
    VALUES (@ExpEne2025_C1, @idConsFullBC, 'Ordinario',
            'Servicio de Agua - Enero 2025', '2025-01-11', 20000.00);
    SET @idGasto = SCOPE_IDENTITY();
END;

IF NOT EXISTS (SELECT 1 FROM app.Tbl_Gasto_Ordinario WHERE idGasto = @idGasto)
BEGIN
    INSERT INTO app.Tbl_Gasto_Ordinario (idGasto, nombreProveedor, categoria, nroFactura)
    VALUES (@idGasto, 'AySA', 'Servicios P�blicos - Agua', 'FAC-AGUA-EN-2025-0001');
END;

-- Internet (solo si el consorcio la tiene configurada)
SELECT @idGasto = idGasto
FROM app.Tbl_Gasto
WHERE idConsorcio = @idConsFullBC AND nroExpensa = @ExpEne2025_C1
  AND descripcion = 'Servicio de Internet - Enero 2025';

IF @idGasto IS NULL
BEGIN
    INSERT INTO app.Tbl_Gasto (nroExpensa, idConsorcio, tipo, descripcion, fechaEmision, importe)
    VALUES (@ExpEne2025_C1, @idConsFullBC, 'Ordinario',
            'Servicio de Internet - Enero 2025', '2025-01-12', 15000.00);
    SET @idGasto = SCOPE_IDENTITY();
END;

IF NOT EXISTS (SELECT 1 FROM app.Tbl_Gasto_Ordinario WHERE idGasto = @idGasto)
BEGIN
    INSERT INTO app.Tbl_Gasto_Ordinario (idGasto, nombreProveedor, categoria, nroFactura)
    VALUES (@idGasto, 'FibraMax', 'Servicios P�blicos - Internet', 'FAC-INT-EN-2025-0001');
END;


-- ========== FEBRERO 2025: GASTOS ORDINARIOS (ejemplo con Opci�n 2 para limpieza) ==========

-- Limpieza Opci�n 2: Empresa de limpieza (un solo gasto)
SELECT @idGasto = idGasto
FROM app.Tbl_Gasto
WHERE idConsorcio = @idConsFullBC AND nroExpensa = @ExpFeb2025_C1
  AND descripcion = 'Servicio de limpieza tercerizado - Febrero 2025';

IF @idGasto IS NULL
BEGIN
    INSERT INTO app.Tbl_Gasto (nroExpensa, idConsorcio, tipo, descripcion, fechaEmision, importe)
    VALUES (@ExpFeb2025_C1, @idConsFullBC, 'Ordinario',
            'Servicio de limpieza tercerizado - Febrero 2025', '2025-02-03', 95000.00);
    SET @idGasto = SCOPE_IDENTITY();
END;

IF NOT EXISTS (SELECT 1 FROM app.Tbl_Gasto_Ordinario WHERE idGasto = @idGasto)
BEGIN
    INSERT INTO app.Tbl_Gasto_Ordinario (idGasto, nombreProveedor, categoria, nroFactura)
    VALUES (@idGasto, 'CleanCorp S.A.', 'Limpieza - Empresa', 'FAC-LIMP-FE-2025-0001');
END;

-- (Pod�s agregar m�s gastos de febrero si quer�s m�s volumen, misma l�gica que enero)


-- ========== MARZO 2025: GASTOS ORDINARIOS + EXTRAORDINARIOS ==========

-- Ejemplo de gasto extraordinario: reparaci�n de fachada, en 3 cuotas (2/3)
SELECT @idGasto = idGasto
FROM app.Tbl_Gasto
WHERE idConsorcio = @idConsFullBC AND nroExpensa = @ExpMar2025_C1
  AND descripcion = 'Reparaci�n de fachada - cuota 2/3';

IF @idGasto IS NULL
BEGIN
    INSERT INTO app.Tbl_Gasto (nroExpensa, idConsorcio, tipo, descripcion, fechaEmision, importe)
    VALUES (@ExpMar2025_C1, @idConsFullBC, 'Extraordinario',
            'Reparaci�n de fachada - cuota 2/3', '2025-03-05', 200000.00);
    SET @idGasto = SCOPE_IDENTITY();
END;

IF NOT EXISTS (SELECT 1 FROM app.Tbl_Gasto_Extraordinario WHERE idGasto = @idGasto)
BEGIN
    INSERT INTO app.Tbl_Gasto_Extraordinario (idGasto, cuotaActual, cantCuotas)
    VALUES (@idGasto, 2, 3);
END;

-- Otro gasto extraordinario: construcci�n de parrilla - pago �nico
SELECT @idGasto = idGasto
FROM app.Tbl_Gasto
WHERE idConsorcio = @idConsFullBC AND nroExpensa = @ExpMar2025_C1
  AND descripcion = 'Construcci�n parrilla SUM - pago �nico';

IF @idGasto IS NULL
BEGIN
    INSERT INTO app.Tbl_Gasto (nroExpensa, idConsorcio, tipo, descripcion, fechaEmision, importe)
    VALUES (@ExpMar2025_C1, @idConsFullBC, 'Extraordinario',
            'Construcci�n parrilla SUM - pago �nico', '2025-03-06', 120000.00);
    SET @idGasto = SCOPE_IDENTITY();
END;

IF NOT EXISTS (SELECT 1 FROM app.Tbl_Gasto_Extraordinario WHERE idGasto = @idGasto)
BEGIN
    INSERT INTO app.Tbl_Gasto_Extraordinario (idGasto, cuotaActual, cantCuotas)
    VALUES (@idGasto, 1, 1);
END;


/* =========================================================
   6. ESTADO DE CUENTA (3 meses) PARA LAS 10 UF DEL CONSORCIO 1
   ========================================================= */

-- Enero 2025: saldo inicial, sin pagos a�n, sin mora
INSERT INTO app.Tbl_EstadoCuenta (
    nroUnidadFuncional, idConsorcio, nroExpensa,
    saldoAnterior, pagoRecibido, deuda, interesMora,
    expensasOrdinarias, expensasExtraordinarias, totalAPagar, fecha
)
SELECT
    UF.idUnidadFuncional,
    @idConsFullBC,
    @ExpEne2025_C1,
    0.00,                    -- saldoAnterior
    0.00,                    -- pagoRecibido
    0.00,                    -- deuda
    0.00,                    -- interesMora
    50000.00,                -- expensasOrdinarias (mismo valor para simplificar)
    0.00,                    -- expensasExtraordinarias
    50000.00,                -- totalAPagar
    '2025-01-31'
FROM app.Tbl_UnidadFuncional UF
WHERE UF.idConsorcio = @idConsFullBC
  AND NOT EXISTS (
        SELECT 1 FROM app.Tbl_EstadoCuenta EC
        WHERE EC.nroUnidadFuncional = UF.idUnidadFuncional
          AND EC.idConsorcio = @idConsFullBC
          AND EC.nroExpensa = @ExpEne2025_C1
  );

-- Febrero 2025: tomamos saldo anterior y simulamos nuevos cargos
INSERT INTO app.Tbl_EstadoCuenta (
    nroUnidadFuncional, idConsorcio, nroExpensa,
    saldoAnterior, pagoRecibido, deuda, interesMora,
    expensasOrdinarias, expensasExtraordinarias, totalAPagar, fecha
)
SELECT
    UF.idUnidadFuncional,
    @idConsFullBC,
    @ExpFeb2025_C1,
    50000.00,                -- saldoAnterior
    0.00,                    -- pagoRecibido (se ajusta por UPDATE para algunos casos)
    50000.00,                -- deuda (se ajusta por UPDATE para algunos casos)
    0.00,                    -- interesMora (se ajusta en UPDATE)
    52000.00,                -- expensasOrdinarias
    0.00,                    -- expensasExtraordinarias
    102000.00,               -- totalAPagar (ejemplo)
    '2025-02-28'
FROM app.Tbl_UnidadFuncional UF
WHERE UF.idConsorcio = @idConsFullBC
  AND NOT EXISTS (
        SELECT 1 FROM app.Tbl_EstadoCuenta EC
        WHERE EC.nroUnidadFuncional = UF.idUnidadFuncional
          AND EC.idConsorcio = @idConsFullBC
          AND EC.nroExpensa = @ExpFeb2025_C1
  );

-- Marzo 2025: incluye extraordinarias
INSERT INTO app.Tbl_EstadoCuenta (
    nroUnidadFuncional, idConsorcio, nroExpensa,
    saldoAnterior, pagoRecibido, deuda, interesMora,
    expensasOrdinarias, expensasExtraordinarias, totalAPagar, fecha
)
SELECT
    UF.idUnidadFuncional,
    @idConsFullBC,
    @ExpMar2025_C1,
    102000.00,               -- saldoAnterior
    0.00,                    -- pagoRecibido
    102000.00,               -- deuda
    0.00,                    -- interesMora
    53000.00,                -- expensasOrdinarias
    15000.00,                -- expensasExtraordinarias
    170000.00,               -- totalAPagar
    '2025-03-31'
FROM app.Tbl_UnidadFuncional UF
WHERE UF.idConsorcio = @idConsFullBC
  AND NOT EXISTS (
        SELECT 1 FROM app.Tbl_EstadoCuenta EC
        WHERE EC.nroUnidadFuncional = UF.idUnidadFuncional
          AND EC.idConsorcio = @idConsFullBC
          AND EC.nroExpensa = @ExpMar2025_C1
  );

/* =========================================================
   7. PAGOS ASOCIADOS (Tbl_Pago) PARA PROBAR FLUJO DE CAJA
   ========================================================= */

-- Pago en t�rmino: UF PB-A, Febrero (antes del 1er vto 2025-02-15)
INSERT INTO app.Tbl_Pago (idEstadoCuenta, nroUnidadFuncional, idConsorcio, nroExpensa, fecha, monto, CBU_CVU)
SELECT
    EC.idEstadoCuenta,
    EC.nroUnidadFuncional,
    EC.idConsorcio,
    EC.nroExpensa,
    '2025-02-10' AS fecha,
    52000.00     AS monto,
    UF.CBU_CVU
FROM app.Tbl_EstadoCuenta EC
JOIN app.Tbl_UnidadFuncional UF
    ON EC.nroUnidadFuncional = UF.idUnidadFuncional
   AND EC.idConsorcio = UF.idConsorcio
WHERE EC.idConsorcio = @idConsFullBC
  AND EC.nroExpensa  = @ExpFeb2025_C1
  AND UF.piso = 0 AND UF.departamento = 'A'
  AND NOT EXISTS (
        SELECT 1 FROM app.Tbl_Pago P
        WHERE P.idEstadoCuenta = EC.idEstadoCuenta
          AND P.fecha = '2025-02-10'
          AND P.monto = 52000.00
  );

-- Pago entre vtos: UF 1-A, Febrero (entre 1er y 2do vto)
INSERT INTO app.Tbl_Pago (idEstadoCuenta, nroUnidadFuncional, idConsorcio, nroExpensa, fecha, monto, CBU_CVU)
SELECT
    EC.idEstadoCuenta,
    EC.nroUnidadFuncional,
    EC.idConsorcio,
    EC.nroExpensa,
    '2025-02-18' AS fecha,
    40000.00     AS monto,
    UF.CBU_CVU
FROM app.Tbl_EstadoCuenta EC
JOIN app.Tbl_UnidadFuncional UF
    ON EC.nroUnidadFuncional = UF.idUnidadFuncional
   AND EC.idConsorcio = UF.idConsorcio
WHERE EC.idConsorcio = @idConsFullBC
  AND EC.nroExpensa  = @ExpFeb2025_C1
  AND UF.piso = 1 AND UF.departamento = 'A'
  AND NOT EXISTS (
        SELECT 1 FROM app.Tbl_Pago P
        WHERE P.idEstadoCuenta = EC.idEstadoCuenta
          AND P.fecha = '2025-02-18'
          AND P.monto = 40000.00
  );

-- Pago posterior al 2do vto: UF 3-B, Febrero
INSERT INTO app.Tbl_Pago (idEstadoCuenta, nroUnidadFuncional, idConsorcio, nroExpensa, fecha, monto, CBU_CVU)
SELECT
    EC.idEstadoCuenta,
    EC.nroUnidadFuncional,
    EC.idConsorcio,
    EC.nroExpensa,
    '2025-03-01' AS fecha,
    30000.00     AS monto,
    UF.CBU_CVU
FROM app.Tbl_EstadoCuenta EC
JOIN app.Tbl_UnidadFuncional UF
    ON EC.nroUnidadFuncional = UF.idUnidadFuncional
   AND EC.idConsorcio = UF.idConsorcio
WHERE EC.idConsorcio = @idConsFullBC
  AND EC.nroExpensa  = @ExpFeb2025_C1
  AND UF.piso = 3 AND UF.departamento = 'B'
  AND NOT EXISTS (
        SELECT 1 FROM app.Tbl_Pago P
        WHERE P.idEstadoCuenta = EC.idEstadoCuenta
          AND P.fecha = '2025-03-01'
          AND P.monto = 30000.00
  );

/*
   Hasta ac�:
   - 4 consorcios con las combinaciones pedidas (baulera / cochera / ninguna / una sola).
   - 10 UF por consorcio (>=10) con % y superficies.
   - 3 meses de expensas para consorcio 1, uno con gastos extraordinarios.
   - Estados de cuenta y pagos con casos de inter�s 0%, 2% y 5%.
   - Este script es re-ejecutable sin duplicar datos (usa IF NOT EXISTS / NOT EXISTS).
*/
GO

-- =====================================================================
-- SmartAttend – NFC Student Attendance Management System
-- Database Schema (MySQL 8.0+)
-- =====================================================================
-- Notes on design decisions:
--  1. `Users` holds login credentials/roles for anyone who accesses the
--     WEB PORTAL (Students, Lecturers, Admins, Faculty Managers, IT Support).
--     The NFC tap itself never touches this table — it's a separate,
--     login-free flow keyed off the physical card UID.
--  2. `Classes` represents a specific scheduled session (a course meeting
--     on a given day/time), separate from `Courses` (the subject itself).
--     Attendance is logged against a Class, not just a Course.
--  3. `Enrollments` is the many-to-many link between Students and Courses,
--     used to validate "Enrolled in This Course?" during check-in.
--  4. Proxy/duplicate prevention is enforced at the DATABASE level via a
--     UNIQUE constraint on (StudentID, ClassID) in Attendance — a second
--     tap for the same student in the same session cannot be inserted
--     as a new row; the application layer instead logs it to
--     AttendanceFlags.
-- =====================================================================

DROP DATABASE IF EXISTS smartattend;
CREATE DATABASE smartattend CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
USE smartattend;

-- ---------------------------------------------------------------------
-- USERS  (portal login accounts — NOT used for NFC tap-in)
-- ---------------------------------------------------------------------
CREATE TABLE Users (
    UserID          INT UNSIGNED AUTO_INCREMENT PRIMARY KEY,
    Email           VARCHAR(150) NOT NULL UNIQUE,
    PasswordHash    VARCHAR(255) NOT NULL,
    Role            ENUM('student','lecturer','admin','faculty_manager','it_support')
                    NOT NULL,
    IsActive        BOOLEAN NOT NULL DEFAULT TRUE,
    CreatedAt       DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
    LastLoginAt     DATETIME NULL
) ENGINE=InnoDB;

-- ---------------------------------------------------------------------
-- STUDENTS
-- ---------------------------------------------------------------------
CREATE TABLE Students (
    StudentID       INT UNSIGNED AUTO_INCREMENT PRIMARY KEY,
    UserID          INT UNSIGNED NULL,                 -- NULL allowed: a student
                                                        -- can exist/tap in before
                                                        -- ever logging into the portal
    StudentNumber   VARCHAR(20) NOT NULL UNIQUE,
    NFCCardUID      VARCHAR(64) NOT NULL UNIQUE,        -- physical card identifier
    Name            VARCHAR(80) NOT NULL,
    Surname         VARCHAR(80) NOT NULL,
    Email           VARCHAR(150) NOT NULL UNIQUE,
    EnrollmentYear  YEAR NOT NULL,
    CONSTRAINT fk_students_user
        FOREIGN KEY (UserID) REFERENCES Users(UserID)
        ON DELETE SET NULL ON UPDATE CASCADE
) ENGINE=InnoDB;

-- ---------------------------------------------------------------------
-- LECTURERS
-- ---------------------------------------------------------------------
CREATE TABLE Lecturers (
    LecturerID      INT UNSIGNED AUTO_INCREMENT PRIMARY KEY,
    UserID          INT UNSIGNED NOT NULL UNIQUE,
    Name            VARCHAR(80) NOT NULL,
    Surname         VARCHAR(80) NOT NULL,
    Email           VARCHAR(150) NOT NULL UNIQUE,
    Department      VARCHAR(100) NULL,
    CONSTRAINT fk_lecturers_user
        FOREIGN KEY (UserID) REFERENCES Users(UserID)
        ON DELETE CASCADE ON UPDATE CASCADE
) ENGINE=InnoDB;

-- ---------------------------------------------------------------------
-- COURSES
-- ---------------------------------------------------------------------
CREATE TABLE Courses (
    CourseID        INT UNSIGNED AUTO_INCREMENT PRIMARY KEY,
    CourseCode      VARCHAR(20) NOT NULL UNIQUE,        -- e.g. COS301
    CourseName      VARCHAR(150) NOT NULL,
    LecturerID      INT UNSIGNED NULL,                  -- primary/coordinating lecturer
    CONSTRAINT fk_courses_lecturer
        FOREIGN KEY (LecturerID) REFERENCES Lecturers(LecturerID)
        ON DELETE SET NULL ON UPDATE CASCADE
) ENGINE=InnoDB;

-- ---------------------------------------------------------------------
-- CLASSES  (a specific scheduled session/instance of a course)
-- ---------------------------------------------------------------------
CREATE TABLE Classes (
    ClassID         INT UNSIGNED AUTO_INCREMENT PRIMARY KEY,
    CourseID        INT UNSIGNED NOT NULL,
    LecturerID      INT UNSIGNED NULL,
    Room            VARCHAR(50) NULL,
    ClassDate       DATE NOT NULL,
    StartTime       TIME NOT NULL,
    EndTime         TIME NOT NULL,
    CONSTRAINT fk_classes_course
        FOREIGN KEY (CourseID) REFERENCES Courses(CourseID)
        ON DELETE CASCADE ON UPDATE CASCADE,
    CONSTRAINT fk_classes_lecturer
        FOREIGN KEY (LecturerID) REFERENCES Lecturers(LecturerID)
        ON DELETE SET NULL ON UPDATE CASCADE,
    CONSTRAINT chk_class_time CHECK (EndTime > StartTime)
) ENGINE=InnoDB;

CREATE INDEX idx_classes_course_date ON Classes(CourseID, ClassDate);

-- ---------------------------------------------------------------------
-- ENROLLMENTS  (many-to-many: Students <-> Courses)
-- ---------------------------------------------------------------------
CREATE TABLE Enrollments (
    EnrollmentID    INT UNSIGNED AUTO_INCREMENT PRIMARY KEY,
    StudentID       INT UNSIGNED NOT NULL,
    CourseID        INT UNSIGNED NOT NULL,
    EnrollmentDate  DATE NOT NULL DEFAULT (CURRENT_DATE),
    CONSTRAINT fk_enroll_student
        FOREIGN KEY (StudentID) REFERENCES Students(StudentID)
        ON DELETE CASCADE ON UPDATE CASCADE,
    CONSTRAINT fk_enroll_course
        FOREIGN KEY (CourseID) REFERENCES Courses(CourseID)
        ON DELETE CASCADE ON UPDATE CASCADE,
    CONSTRAINT uq_student_course UNIQUE (StudentID, CourseID)
) ENGINE=InnoDB;

-- ---------------------------------------------------------------------
-- ATTENDANCE  (one valid check-in per student per class)
-- ---------------------------------------------------------------------
CREATE TABLE Attendance (
    AttendanceID    INT UNSIGNED AUTO_INCREMENT PRIMARY KEY,
    StudentID       INT UNSIGNED NOT NULL,
    ClassID         INT UNSIGNED NOT NULL,
    CheckInTime     DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
    Status          ENUM('present','late') NOT NULL DEFAULT 'present',
    CONSTRAINT fk_attendance_student
        FOREIGN KEY (StudentID) REFERENCES Students(StudentID)
        ON DELETE CASCADE ON UPDATE CASCADE,
    CONSTRAINT fk_attendance_class
        FOREIGN KEY (ClassID) REFERENCES Classes(ClassID)
        ON DELETE CASCADE ON UPDATE CASCADE,
    -- Core proxy/duplicate-prevention rule: a student can only have ONE
    -- valid attendance row per class session.
    CONSTRAINT uq_student_class UNIQUE (StudentID, ClassID)
) ENGINE=InnoDB;

CREATE INDEX idx_attendance_class ON Attendance(ClassID);
CREATE INDEX idx_attendance_student ON Attendance(StudentID);

-- ---------------------------------------------------------------------
-- ATTENDANCE FLAGS  (rejected taps: invalid card, not enrolled, proxy)
-- Kept separate from Attendance so successful records stay clean while
-- still preserving an audit trail of suspicious/rejected tap attempts.
-- ---------------------------------------------------------------------
CREATE TABLE AttendanceFlags (
    FlagID          INT UNSIGNED AUTO_INCREMENT PRIMARY KEY,
    StudentID       INT UNSIGNED NULL,          -- NULL if card wasn't recognised at all
    ClassID         INT UNSIGNED NULL,
    NFCCardUID      VARCHAR(64) NULL,
    Reason          ENUM('invalid_card','not_enrolled','duplicate_tap') NOT NULL,
    AttemptedAt     DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
    CONSTRAINT fk_flags_student
        FOREIGN KEY (StudentID) REFERENCES Students(StudentID)
        ON DELETE SET NULL ON UPDATE CASCADE,
    CONSTRAINT fk_flags_class
        FOREIGN KEY (ClassID) REFERENCES Classes(ClassID)
        ON DELETE SET NULL ON UPDATE CASCADE
) ENGINE=InnoDB;

CREATE INDEX idx_flags_class ON AttendanceFlags(ClassID);

-- ---------------------------------------------------------------------
-- NFC DEVICES  (readers installed in classrooms; IT Support monitors these)
-- ---------------------------------------------------------------------
CREATE TABLE NFCDevices (
    DeviceID        INT UNSIGNED AUTO_INCREMENT PRIMARY KEY,
    DeviceLabel     VARCHAR(50) NOT NULL UNIQUE,      -- e.g. "IT4-1-READER-01"
    Room            VARCHAR(50) NOT NULL,
    Status          ENUM('online','offline','maintenance') NOT NULL DEFAULT 'offline',
    LastHeartbeat   DATETIME NULL,
    InstalledAt     DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP
) ENGINE=InnoDB;

-- =====================================================================
-- SAMPLE DATA (for testing / demo purposes)
-- =====================================================================
INSERT INTO Users (Email, PasswordHash, Role) VALUES
('n.dlamini@uni.ac', 'HASHED_PLACEHOLDER_1', 'lecturer'),
('admin@uni.ac', 'HASHED_PLACEHOLDER_2', 'admin'),
('p.naicker@uni.ac', 'HASHED_PLACEHOLDER_3', 'it_support');

INSERT INTO Lecturers (UserID, Name, Surname, Email, Department) VALUES
(1, 'N.', 'Dlamini', 'n.dlamini@uni.ac', 'Computer Science');

INSERT INTO Students (StudentNumber, NFCCardUID, Name, Surname, Email, EnrollmentYear) VALUES
('u21345678', 'CARD-UID-0001', 'Thabo', 'Mokoena', 'u21345678@uni.ac', 2023),
('u21987654', 'CARD-UID-0002', 'Lerato', 'van Wyk', 'u21987654@uni.ac', 2022);

INSERT INTO Courses (CourseCode, CourseName, LecturerID) VALUES
('COS301', 'Software Engineering', 1);

INSERT INTO Classes (CourseID, LecturerID, Room, ClassDate, StartTime, EndTime) VALUES
(1, 1, 'IT4-1', '2026-07-06', '08:00:00', '09:00:00');

INSERT INTO Enrollments (StudentID, CourseID) VALUES
(1, 1),
(2, 1);

INSERT INTO Attendance (StudentID, ClassID, Status) VALUES
(1, 1, 'present'),
(2, 1, 'present');

-- Attempting a second tap for StudentID 1 in ClassID 1 would violate
-- uq_student_class — the application should catch this and instead
-- insert into AttendanceFlags with Reason = 'duplicate_tap':
-- INSERT INTO Attendance (StudentID, ClassID) VALUES (1, 1); -- would FAIL
INSERT INTO AttendanceFlags (StudentID, ClassID, NFCCardUID, Reason) VALUES
(1, 1, 'CARD-UID-0001', 'duplicate_tap');

INSERT INTO NFCDevices (DeviceLabel, Room, Status, LastHeartbeat) VALUES
('IT4-1-READER-01', 'IT4-1', 'online', NOW());

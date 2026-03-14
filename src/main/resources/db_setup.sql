-- ============================================================
-- EduStack — Database Schema & Seed Data
-- Database: edustack
-- Author: Samson Olanipekun (github.com/Reich-imperial)
-- ============================================================

USE edustack;

-- ── Users table (students + staff) ──────────────────────────
CREATE TABLE IF NOT EXISTS users (
    id          INT AUTO_INCREMENT PRIMARY KEY,
    username    VARCHAR(50)  NOT NULL UNIQUE,
    email       VARCHAR(100) NOT NULL UNIQUE,
    password    VARCHAR(255) NOT NULL,
    role        ENUM('student','lecturer','admin') DEFAULT 'student',
    full_name   VARCHAR(100),
    department  VARCHAR(100),
    created_at  TIMESTAMP DEFAULT CURRENT_TIMESTAMP
);

-- ── Courses table ────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS courses (
    id          INT AUTO_INCREMENT PRIMARY KEY,
    code        VARCHAR(20) NOT NULL UNIQUE,
    title       VARCHAR(200) NOT NULL,
    department  VARCHAR(100),
    credits     INT DEFAULT 3,
    lecturer_id INT,
    FOREIGN KEY (lecturer_id) REFERENCES users(id)
);

-- ── Enrolments table ─────────────────────────────────────────
CREATE TABLE IF NOT EXISTS enrolments (
    id          INT AUTO_INCREMENT PRIMARY KEY,
    student_id  INT NOT NULL,
    course_id   INT NOT NULL,
    session     VARCHAR(20) NOT NULL,
    enrolled_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    FOREIGN KEY (student_id) REFERENCES users(id),
    FOREIGN KEY (course_id)  REFERENCES courses(id),
    UNIQUE KEY unique_enrolment (student_id, course_id, session)
);

-- ── Grades table ─────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS grades (
    id          INT AUTO_INCREMENT PRIMARY KEY,
    student_id  INT NOT NULL,
    course_id   INT NOT NULL,
    score       DECIMAL(5,2),
    grade       VARCHAR(5),
    session     VARCHAR(20),
    updated_at  TIMESTAMP DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
    FOREIGN KEY (student_id) REFERENCES users(id),
    FOREIGN KEY (course_id)  REFERENCES courses(id)
);

-- ── Announcements table ──────────────────────────────────────
CREATE TABLE IF NOT EXISTS announcements (
    id          INT AUTO_INCREMENT PRIMARY KEY,
    title       VARCHAR(200) NOT NULL,
    body        TEXT,
    author_id   INT,
    created_at  TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    FOREIGN KEY (author_id) REFERENCES users(id)
);

-- ── Seed data — demo accounts ────────────────────────────────
-- Password for all demo accounts: EduStack@2026
-- (BCrypt hashed in production — plaintext here for dev only)

INSERT INTO users (username, email, password, role, full_name, department) VALUES
('admin_vp',   'admin@edustack.local',   'EduStack@2026', 'admin',    'Portal Administrator', 'IT Services'),
('samson.o',   'samson@edustack.local',  'EduStack@2026', 'student',  'Samson Olanipekun',    'Computer Science'),
('dr.adeyemi', 'adeyemi@edustack.local', 'EduStack@2026', 'lecturer', 'Dr. Adeyemi Folake',   'Computer Science'),
('bola.k',     'bola@edustack.local',    'EduStack@2026', 'student',  'Bolaji Kehinde',       'Electrical Engineering'),
('tunde.a',    'tunde@edustack.local',   'EduStack@2026', 'student',  'Tunde Akinlabi',       'Computer Science')
ON DUPLICATE KEY UPDATE username=username;

INSERT INTO courses (code, title, department, credits, lecturer_id) VALUES
('CSC301', 'Operating Systems',           'Computer Science',        3, 3),
('CSC302', 'Computer Networks',           'Computer Science',        3, 3),
('CSC303', 'Database Management Systems', 'Computer Science',        3, 3),
('EEE201', 'Circuit Theory',              'Electrical Engineering',  3, NULL),
('CSC401', 'DevOps Engineering',          'Computer Science',        3, 3)
ON DUPLICATE KEY UPDATE code=code;

INSERT INTO enrolments (student_id, course_id, session) VALUES
(2, 1, '2025/2026'), (2, 2, '2025/2026'), (2, 3, '2025/2026'), (2, 5, '2025/2026'),
(4, 4, '2025/2026'),
(5, 1, '2025/2026'), (5, 2, '2025/2026'), (5, 5, '2025/2026')
ON DUPLICATE KEY UPDATE student_id=student_id;

INSERT INTO grades (student_id, course_id, score, grade, session) VALUES
(2, 1, 78.50, 'B', '2025/2026'),
(2, 2, 85.00, 'A', '2025/2026'),
(2, 3, 91.00, 'A', '2025/2026'),
(5, 1, 72.00, 'B', '2025/2026'),
(5, 2, 68.50, 'C', '2025/2026')
ON DUPLICATE KEY UPDATE score=score;

INSERT INTO announcements (title, body, author_id) VALUES
('Welcome to EduStack Portal', 'The new student portal is live. Log in with your student credentials.', 1),
('CSC401 DevOps Lab Starts Monday', 'All CSC401 students report to Lab 3 on Monday for practical sessions.', 3),
('Exam Timetable — 2025/2026 Session', 'The semester exam timetable has been published. Check your course dashboard.', 1)
ON DUPLICATE KEY UPDATE title=title;

FLUSH PRIVILEGES;

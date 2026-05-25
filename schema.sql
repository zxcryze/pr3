-- ======================================================
-- База данных: eco_farm_booking_variant1
-- Тема: Онлайн-запись на экскурсии в эко-ферму
-- Ограничения: сезонность, возраст, макс. участников, связка ребёнок+взрослый
-- ======================================================

DROP DATABASE IF EXISTS eco_farm_booking_variant1;
CREATE DATABASE eco_farm_booking_variant1
    CHARACTER SET utf8mb4
    COLLATE utf8mb4_unicode_ci;
USE eco_farm_booking_variant1;

-- ======================================================
-- 1. Таблица сезонов (справочник)
-- ======================================================
CREATE TABLE seasons (
    season_id   INT AUTO_INCREMENT PRIMARY KEY,
    season_name ENUM('Весна', 'Лето', 'Осень', 'Зима') NOT NULL UNIQUE
);

-- ======================================================
-- 2. Таблица тем экскурсий (ведёт экскурсовод)
-- ======================================================
CREATE TABLE tour_topics (
    topic_id   INT AUTO_INCREMENT PRIMARY KEY,
    topic_name VARCHAR(100) NOT NULL UNIQUE, -- 'Растениеводство', 'Животноводство'
    guide_name VARCHAR(100) NOT NULL
);

-- ======================================================
-- 3. Таблица мероприятий (с сезонностью и ограничениями)
-- ======================================================
CREATE TABLE farm_events (
    event_id          INT AUTO_INCREMENT PRIMARY KEY,
    event_name        VARCHAR(150) NOT NULL,
    season_id         INT NOT NULL,
    topic_id          INT NOT NULL,
    min_age           INT DEFAULT 0,          -- минимальный возраст участника
    max_participants  INT NOT NULL CHECK (max_participants > 0),
    duration_minutes  INT NOT NULL,
    -- бизнес-правило: если возраст <12, то требуется сопровождение взрослым
    requires_accompaniment BOOLEAN GENERATED ALWAYS AS (min_age < 12) STORED,
    FOREIGN KEY (season_id) REFERENCES seasons(season_id) ON DELETE RESTRICT,
    FOREIGN KEY (topic_id)  REFERENCES tour_topics(topic_id)  ON DELETE RESTRICT
);

-- ======================================================
-- 4. Таблица пользователей (гостей фермы)
-- ======================================================
CREATE TABLE farm_visitors (
    visitor_id   INT AUTO_INCREMENT PRIMARY KEY,
    full_name    VARCHAR(150) NOT NULL,
    birth_date   DATE NOT NULL,
    phone        VARCHAR(20) NOT NULL UNIQUE,
    email        VARCHAR(100) NOT NULL UNIQUE,
    -- вычисляемый возраст на момент записи (проверка через триггер/приложение, но CHECK не умеет CURDATE)
    CHECK (birth_date <= '2016-01-01') -- условно: дети до 12 лет в 2026 году
);

-- ======================================================
-- 5. Таблица записей на мероприятия (основная)
-- ======================================================
CREATE TABLE event_bookings (
    booking_id      INT AUTO_INCREMENT PRIMARY KEY,
    event_id        INT NOT NULL,
    visitor_id      INT NOT NULL,
    booking_date    DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
    event_date      DATETIME NOT NULL,    -- дата проведения мероприятия
    status          ENUM('active', 'cancelled', 'completed') DEFAULT 'active',
    -- Связка ребёнок + взрослый: если ребёнку <12, то должен быть companion_booking_id
    companion_booking_id INT NULL,
    FOREIGN KEY (event_id) REFERENCES farm_events(event_id) ON DELETE RESTRICT,
    FOREIGN KEY (visitor_id) REFERENCES farm_visitors(visitor_id) ON DELETE RESTRICT,
    FOREIGN KEY (companion_booking_id) REFERENCES event_bookings(booking_id) ON DELETE SET NULL,
    -- Уникальность: один человек не может записаться на одно и то же событие дважды
    UNIQUE KEY unique_visitor_event (visitor_id, event_id),
    -- Индекс для быстрого поиска по дате
    INDEX idx_event_date (event_date)
);

-- ======================================================
-- 6. Таблица отзывов о ферме (с оценками)
-- ======================================================
CREATE TABLE farm_reviews (
    review_id   INT AUTO_INCREMENT PRIMARY KEY,
    visitor_id  INT NOT NULL,
    rating      INT NOT NULL CHECK (rating BETWEEN 1 AND 5),
    comment     TEXT,
    review_date DATETIME DEFAULT CURRENT_TIMESTAMP,
    FOREIGN KEY (visitor_id) REFERENCES farm_visitors(visitor_id) ON DELETE CASCADE
);

-- ======================================================
-- 7. Триггер для проверки возраста и наличия сопровождающего
-- (реализация бизнес-правила "ребёнок до 12 лет только с взрослым")
-- ======================================================
DELIMITER $$

CREATE TRIGGER check_age_and_companion
BEFORE INSERT ON event_bookings
FOR EACH ROW
BEGIN
    DECLARE visitor_age INT;
    DECLARE event_min_age INT;
    DECLARE companion_age INT;

    -- возраст посетителя
    SELECT TIMESTAMPDIFF(YEAR, birth_date, CURDATE()) INTO visitor_age
    FROM farm_visitors WHERE visitor_id = NEW.visitor_id;

    -- минимальный возраст мероприятия
    SELECT min_age INTO event_min_age
    FROM farm_events WHERE event_id = NEW.event_id;

    IF visitor_age < event_min_age THEN
        SIGNAL SQLSTATE '45000'
        SET MESSAGE_TEXT = 'Возраст посетителя меньше минимального для данного мероприятия';
    END IF;

    -- Ребёнок до 12 лет должен иметь сопровождающего (companion_booking_id не NULL)
    IF visitor_age < 12 AND NEW.companion_booking_id IS NULL THEN
        SIGNAL SQLSTATE '45001'
        SET MESSAGE_TEXT = 'Ребёнок до 12 лет может записаться только с сопровождающим (укажите companion_booking_id)';
    END IF;

    -- Если есть сопровождающий, проверим что его возраст >= 18
    IF NEW.companion_booking_id IS NOT NULL THEN
        SELECT TIMESTAMPDIFF(YEAR, fv.birth_date, CURDATE()) INTO companion_age
        FROM event_bookings eb
        JOIN farm_visitors fv ON eb.visitor_id = fv.visitor_id
        WHERE eb.booking_id = NEW.companion_booking_id;

        IF companion_age < 18 THEN
            SIGNAL SQLSTATE '45002'
            SET MESSAGE_TEXT = 'Сопровождающий должен быть старше 18 лет';
        END IF;
    END IF;
END$$

DELIMITER ;

-- ======================================================
-- 8. Тестовые данные
-- ======================================================
INSERT INTO seasons (season_name) VALUES ('Весна'), ('Лето'), ('Осень'), ('Зима');

INSERT INTO tour_topics (topic_name, guide_name) VALUES
('Растениеводство', 'Анна Петровна'),
('Животноводство', 'Иван Сергеевич');

INSERT INTO farm_events (event_name, season_id, topic_id, min_age, max_participants, duration_minutes) VALUES
('Посев семян',     1, 1, 6, 20, 90),   -- Весна, дети 6+, сопровождение нужно (6<12)
('Доение коз',      2, 2, 12, 15, 60),  -- Лето, с 12 лет, сопровождение НЕ нужно
('Сбор яблок',      3, 1, 5, 25, 120),  -- Осень, малыши только с взрослым
('Кормление овец',  4, 2, 10, 10, 45),  -- Зима
('Уход за теплицей',1, 1, 16, 12, 90);  -- Весна, только подростки/взрослые

INSERT INTO farm_visitors (full_name, birth_date, phone, email) VALUES
('Иван Петров',     '2015-05-10', '+79111111111', 'ivan@mail.ru'),   -- 11 лет (ребёнок)
('Ольга Петрова',   '1990-02-20', '+79222222222', 'olga@mail.ru'),   -- мама
('Дмитрий Сидоров', '2005-07-15', '+79333333333', 'dima@mail.ru'),   -- 21 год
('Елена Морозова',  '2018-11-02', '+79444444444', 'elena@mail.ru'),   -- 8 лет
('Анна Морозова',   '1985-03-25', '+79555555555', 'anna@mail.ru');    -- мама

-- Запись ребёнка с сопровождающим (связка двух записей)
INSERT INTO event_bookings (event_id, visitor_id, event_date, companion_booking_id, status) VALUES
(1, 1, '2026-05-15 10:00:00', NULL, 'active'); -- сначала создаём запись ребёнка (companion NULL временно)
SET @child_booking = LAST_INSERT_ID();
INSERT INTO event_bookings (event_id, visitor_id, event_date, companion_booking_id, status) VALUES
(1, 2, '2026-05-15 10:00:00', @child_booking, 'active');
UPDATE event_bookings SET companion_booking_id = @child_booking WHERE booking_id = @child_booking;
UPDATE event_bookings SET companion_booking_id = (SELECT booking_id FROM event_bookings WHERE visitor_id = 2 AND event_id = 1)
WHERE booking_id = @child_booking;

-- Простые записи взрослых
INSERT INTO event_bookings (event_id, visitor_id, event_date, companion_booking_id) VALUES
(2, 3, '2026-07-10 14:00:00', NULL),
(4, 3, '2026-12-01 11:00:00', NULL);

INSERT INTO farm_reviews (visitor_id, rating, comment) VALUES
(2, 5, 'Очень интересно!'),
(3, 4, 'Козочки милые, но холодно было'),
(1, 5, 'Мама помогла, мне понравилось сеять');

-- ======================================================
-- 9. ЗАПРОСЫ (минимум 3 типа)
-- ======================================================

-- 1) JOIN трёх таблиц: мероприятия + темы + количество отзывов
SELECT 
    e.event_name,
    t.topic_name,
    t.guide_name,
    COUNT(r.review_id) AS review_count,
    AVG(r.rating) AS avg_rating
FROM farm_events e
JOIN tour_topics t ON e.topic_id = t.topic_id
LEFT JOIN event_bookings b ON e.event_id = b.event_id
LEFT JOIN farm_reviews r ON b.visitor_id = r.visitor_id
GROUP BY e.event_id
ORDER BY review_count DESC;

-- 2) Группировка с HAVING: популярные мероприятия по сезонам (записано больше 1 человека)
SELECT 
    s.season_name,
    e.event_name,
    COUNT(b.booking_id) AS total_bookings
FROM farm_events e
JOIN seasons s ON e.season_id = s.season_id
JOIN event_bookings b ON e.event_id = b.event_id
GROUP BY e.event_id
HAVING total_bookings > 1
ORDER BY s.season_name, total_bookings DESC;

-- 3) Подзапрос: мероприятия, у которых максимальное число участников выше среднего по сезону
SELECT 
    season_id,
    event_name,
    max_participants
FROM farm_events e1
WHERE max_participants > (
    SELECT AVG(max_participants)
    FROM farm_events e2
    WHERE e2.season_id = e1.season_id
);

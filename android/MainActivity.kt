/* ============================================================================
 *  MainActivity.kt — «Пульт управления» ArsenBlocker для Android (нативно)
 *  Система: ArsenBlocker  |  Версия: 1.0.0  |  Протокол: v1
 * ----------------------------------------------------------------------------
 *  ЧТО ЭТО: одноэкранное приложение с кнопками. Интерфейс собирается прямо в
 *  коде — отдельный файл разметки (layout XML) НЕ нужен, поэтому файл всего
 *  один и его легко вставить в новый проект Android Studio.
 *
 *  КАК ПОЛЬЗОВАТЬСЯ (подробная пошаговая инструкция — в ARCHITECTURE.md):
 *   1) Откройте Android Studio -> New Project -> "Empty Views Activity".
 *       Язык — Kotlin, минимальная версия Android — API 24.
 *   2) Замените содержимое файла MainActivity.kt на этот текст
 *       (файл лежит по пути app/src/main/java/<ваш_пакет>/MainActivity.kt).
 *   3) В файл AndroidManifest.xml добавьте разрешение INTERNET
 *       (готовый фрагмент — в файле AndroidManifest_snippet.xml).
 *   4) В build.gradle (Module: app) добавьте зависимость appcompat
 *       (готовый фрагмент — в файле build_gradle_snippet.txt).
 *   5) Нажмите Run и установите приложение на телефон.
 *
 *  Приложение помнит IP, порт и токен (SharedPreferences), поэтому вводить
 *  их нужно один раз. Если рядом есть файл /sdcard/ArsenBlocker/client.json
 *  (его создаёт пульт для Termux) — приложение попробует прочитать настройки
 *  из него при первом запуске, чтобы ничего не вводить вручную.
 * ========================================================================== */

package com.arsen.blocker

import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.text.InputType
import android.view.Gravity
import android.view.ViewGroup
import android.widget.ArrayAdapter
import android.widget.Button
import android.widget.CheckBox
import android.widget.EditText
import android.widget.LinearLayout
import android.widget.ScrollView
import android.widget.Spinner
import android.widget.TextView
import android.widget.Toast
import androidx.appcompat.app.AlertDialog
import androidx.appcompat.app.AppCompatActivity
import org.json.JSONObject
import java.io.BufferedReader
import java.io.File
import java.io.InputStreamReader
import java.io.OutputStreamWriter
import java.net.InetSocketAddress
import java.net.Socket
import java.security.SecureRandom
import javax.crypto.Mac
import javax.crypto.spec.SecretKeySpec

class MainActivity : AppCompatActivity() {

    // --- Поля ввода и элементы интерфейса ---
    private lateinit var etHost: EditText
    private lateinit var etPort: EditText
    private lateinit var etToken: EditText
    private lateinit var cbHmac: CheckBox
    private lateinit var etMinutes: EditText
    private lateinit var spUsers: Spinner
    private lateinit var tvLog: TextView

    // --- Настройки доступа (совпадают с config.json на ПК) ---
    private val protocolVersion = "v1"

    // Хранилище настроек на телефоне (переживает обновление приложения)
    private val prefs by lazy { getSharedPreferences("arsen_blocker", MODE_PRIVATE) }

    // Последний полученный список пользователей ПК
    private var users: List<String> = emptyList()

    // Для обновления интерфейса из фонового потока
    private val ui = Handler(Looper.getMainLooper())

    // Путь к общему файлу настроек (его же использует пульт для Termux)
    private val sharedConfigPath = "/sdcard/ArsenBlocker/client.json"

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        setContentView(buildLayout())
        loadSettings()

        btnPing.setOnClickListener { sendCommand("ping", "") }
        btnUsers.setOnClickListener { sendCommand("users", "") }
        btnBlock.setOnClickListener {
            val user = spUsers.selectedItem?.toString() ?: ""
            if (user.isEmpty()) {
                log("Сначала нажмите «Обновить список пользователей».")
            } else {
                sendCommand("block", user)
            }
        }
        btnUnblock.setOnClickListener { sendCommand("unblock", "") }
        btnSave.setOnClickListener { saveSettings() }
    }

    /* =========================================================================
     *  ИНТЕРФЕЙС (собирается кодом, без XML-разметки)
     * ====================================================================== */

    private lateinit var btnPing: Button
    private lateinit var btnUsers: Button
    private lateinit var btnBlock: Button
    private lateinit var btnUnblock: Button
    private lateinit var btnSave: Button

    private fun buildLayout(): ScrollView {
        val pad = (16 * resources.displayMetrics.density).toInt()
        val root = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            setPadding(pad, pad, pad, pad)
        }

        fun label(text: String): TextView = TextView(this).apply {
            this.text = text
            textSize = 14f
            setPadding(0, pad / 2, 0, 0)
        }

        root.addView(TextView(this).apply {
            text = "ArsenBlocker — пульт управления"
            textSize = 20f
            gravity = Gravity.CENTER
        })

        // --- Настройки подключения ---
        root.addView(label("IP-адрес компьютера (например 192.168.1.50)"))
        etHost = EditText(this).apply {
            inputType = InputType.TYPE_CLASS_TEXT
            hint = "192.168.1.50"
        }
        root.addView(etHost)

        root.addView(label("Порт (по умолчанию 9099)"))
        etPort = EditText(this).apply {
            inputType = InputType.TYPE_CLASS_NUMBER
            hint = "9099"
        }
        root.addView(etPort)

        root.addView(label("Токен доступа (показан при установке агента на ПК)"))
        etToken = EditText(this).apply {
            inputType = InputType.TYPE_CLASS_TEXT
            hint = "вставьте токен"
        }
        root.addView(etToken)

        cbHmac = CheckBox(this).apply {
            text = "Подписывать запросы (HMAC) — рекомендуется"
            isChecked = true
        }
        root.addView(cbHmac)

        btnSave = Button(this).apply { text = "Сохранить настройки" }
        root.addView(btnSave)

        // --- Действия ---
        root.addView(label("1. Проверка связи"))
        btnPing = Button(this).apply { text = "Проверить связь (пинг)" }
        root.addView(btnPing)

        root.addView(label("2. Список пользователей компьютера"))
        btnUsers = Button(this).apply { text = "Обновить список пользователей" }
        root.addView(btnUsers)

        spUsers = Spinner(this)
        root.addView(
            spUsers,
            LinearLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT)
        )

        // --- Блокировка ---
        root.addView(label("3. Время блокировки в минутах"))
        etMinutes = EditText(this).apply {
            inputType = InputType.TYPE_CLASS_NUMBER
            setText("30")
        }
        root.addView(etMinutes)

        // Быстрые кнопки времени
        val quickRow = LinearLayout(this).apply { orientation = LinearLayout.HORIZONTAL }
        listOf(15, 30, 60, 120).forEach { minutes ->
            quickRow.addView(Button(this).apply {
                text = "$minutes"
                setOnClickListener { etMinutes.setText(minutes.toString()) }
            })
        }
        root.addView(quickRow)

        btnBlock = Button(this).apply { text = "ОТПРАВИТЬ: заблокировать выбранного" }
        root.addView(btnBlock)

        btnUnblock = Button(this).apply { text = "Снять все блокировки" }
        root.addView(btnUnblock)

        // --- Журнал ---
        root.addView(label("Журнал"))
        tvLog = TextView(this).apply {
            textSize = 13f
            typeface = android.graphics.Typeface.MONOSPACE
            setTextIsSelectable(true)
            text = "Готово к работе.\n"
        }
        root.addView(tvLog)

        return ScrollView(this).apply { addView(root) }
    }

    /* =========================================================================
     *  СОХРАНЕНИЕ / ЗАГРУЗКА НАСТРОЕК
     * ====================================================================== */

    private fun saveSettings() {
        prefs.edit()
            .putString("host", etHost.text.toString().trim())
            .putInt("port", etPort.text.toString().trim().toIntOrNull() ?: 9099)
            .putString("token", etToken.text.toString().trim())
            .putBoolean("hmac", cbHmac.isChecked)
            .apply()
        Toast.makeText(this, "Настройки сохранены", Toast.LENGTH_SHORT).show()
        log("Настройки сохранены на телефоне.\n")
    }

    private fun loadSettings() {
        var host = prefs.getString("host", "") ?: ""
        var port = prefs.getInt("port", 9099)
        var token = prefs.getString("token", "") ?: ""
        var hmac = prefs.getBoolean("hmac", true)

        // Если своих настроек ещё нет — пробуем прочитать общий файл
        // /sdcard/ArsenBlocker/client.json (тот же, что у пульта для Termux)
        if (host.isEmpty() || token.isEmpty()) {
            try {
                val file = File(sharedConfigPath)
                if (file.exists()) {
                    val json = JSONObject(file.readText())
                    host = json.optString("host", host)
                    port = json.optInt("port", port)
                    token = json.optString("token", token)
                    hmac = json.optString("security", "hmac") == "hmac"
                    log("Настройки импортированы из $sharedConfigPath\n")
                }
            } catch (e: Exception) {
                log("Не удалось прочитать общий файл настроек: ${e.message}\n")
            }
        }

        etHost.setText(host)
        etPort.setText(port.toString())
        etToken.setText(token)
        cbHmac.isChecked = hmac
    }

    /* =========================================================================
     *  ОТПРАВКА КОМАНД (в фоновом потоке, чтобы не «подвешивать» интерфейс)
     * ====================================================================== */

    private fun sendCommand(cmd: String, user: String) {
        val host = etHost.text.toString().trim()
        val port = etPort.text.toString().trim().toIntOrNull() ?: 9099
        val token = etToken.text.toString().trim()
        val hmac = cbHmac.isChecked
        val minutes = etMinutes.text.toString().trim().toIntOrNull() ?: 30

        if (host.isEmpty() || token.isEmpty()) {
            log("Заполните IP-адрес и токен доступа.\n")
            return
        }

        log("→ $cmd ${if (user.isNotEmpty()) "($user, $minutes мин.)" else ""}\n")

        Thread {
            val request = buildRequest(cmd, user, minutes, token, hmac)
            val response = sendRaw(host, port, request.toString())
            ui.post {
                log("← ${response.optString("message", response.toString())}\n")

                // Разбираем список пользователей
                if (response.optBoolean("ok", false)) {
                    val data = response.optJSONObject("data")
                    val usersArray = data?.optJSONArray("users")
                    if (usersArray != null) {
                        val list = ArrayList<String>()
                        for (i in 0 until usersArray.length()) {
                            val item = usersArray.getJSONObject(i)
                            val login = item.optString("user")
                            val active = if (item.optBoolean("active")) "В СИСТЕМЕ" else "не активен"
                            val blocked = item.optInt("remaining_min", 0)
                            val tail = if (blocked > 0) " [блок: $blocked мин.]" else ""
                            list.add("$login — $active$tail")
                        }
                        users = list
                        spUsers.adapter = ArrayAdapter(
                            this, android.R.layout.simple_spinner_dropdown_item, users
                        )
                    }
                }

                // Требуется подтверждение блокировки администратора
                if (!response.optBoolean("ok", false) && response.optBoolean("need_force", false)) {
                    AlertDialog.Builder(this)
                        .setTitle("Это администратор")
                        .setMessage("Пользователь «$user» — администратор. Заблокировать всё равно?")
                        .setPositiveButton("Заблокировать") { _, _ -> sendForce(user, minutes, token, host, port, hmac) }
                        .setNegativeButton("Отмена", null)
                        .show()
                }
            }
        }.start()
    }

    private fun sendForce(user: String, minutes: Int, token: String, host: String, port: Int, hmac: Boolean) {
        Thread {
            val request = buildRequest("block", user, minutes, token, hmac, force = true)
            val response = sendRaw(host, port, request.toString())
            ui.post { log("← (подтверждено) ${response.optString("message", response.toString())}\n") }
        }.start()
    }

    /** Формирует запрос с подписью — формат совпадает с block_agent.ps1 и client_tui.py. */
    private fun buildRequest(
        cmd: String,
        user: String,
        minutes: Int,
        token: String,
        hmac: Boolean,
        force: Boolean = false
    ): JSONObject {
        val ts = System.currentTimeMillis() / 1000
        val nonce = randomHex(16)

        val json = JSONObject()
        json.put("cmd", cmd)
        json.put("user", user)
        json.put("minutes", minutes)
        json.put("ts", ts)
        json.put("nonce", nonce)
        if (force) json.put("force", true)

        if (hmac) {
            // Строка для подписи: v1|команда|пользователь|минуты|время|одноразовый код
            val canonical = "$protocolVersion|${cmd.lowercase()}|$user|$minutes|$ts|$nonce"
            json.put("sig", hmacSha256Hex(token, canonical))
        } else {
            json.put("token", token)
        }
        return json
    }

    private fun hmacSha256Hex(key: String, text: String): String {
        val mac = Mac.getInstance("HmacSHA256")
        mac.init(SecretKeySpec(key.toByteArray(Charsets.UTF_8), "HmacSHA256"))
        val bytes = mac.doFinal(text.toByteArray(Charsets.UTF_8))
        return bytes.joinToString("") { (it.toInt() and 0xFF).toString(16).padStart(2, '0') }
    }

    private fun randomHex(length: Int): String {
        val random = SecureRandom()
        val bytes = ByteArray(length / 2)
        random.nextBytes(bytes)
        return bytes.joinToString("") { (it.toInt() and 0xFF).toString(16).padStart(2, '0') }
    }

    /** Отправляет одну строку JSON на ПК и читает одну строку ответа. */
    private fun sendRaw(host: String, port: Int, payload: String): JSONObject {
        return try {
            Socket().use { socket ->
                socket.connect(InetSocketAddress(host, port), 5000)
                socket.soTimeout = 8000

                OutputStreamWriter(socket.getOutputStream(), "UTF-8").use { writer ->
                    writer.write(payload + "\n")
                    writer.flush()
                }
                val line = BufferedReader(InputStreamReader(socket.getInputStream(), "UTF-8")).readLine()
                if (line.isNullOrBlank()) JSONObject().put("ok", false).put("message", "пустой ответ от ПК")
                else JSONObject(line)
            }
        } catch (e: Exception) {
            JSONObject().put("ok", false).put("message", "ошибка связи: ${e.message}")
        }
    }

    private fun log(text: String) {
        tvLog.append(text)
        // Прокручиваем вниз, чтобы был виден свежий ответ
        (tvLog.parent as? ScrollView)?.post { (tvLog.parent as? ScrollView)?.fullScroll(ScrollView.FOCUS_DOWN) }
    }
}
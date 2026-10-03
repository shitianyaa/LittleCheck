package dev.littlecheck.little_check

import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import android.content.Intent
import android.provider.OpenableColumns
import java.io.ByteArrayOutputStream
import java.nio.ByteBuffer
import java.nio.charset.CodingErrorAction
import java.util.concurrent.Executors

class MainActivity : FlutterActivity() {
    private var documents: MethodChannel? = null
    private val pending = mutableListOf<Intent>()
    private val worker = Executors.newSingleThreadExecutor()

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        if (intent.action == Intent.ACTION_VIEW) pending.add(intent)
        documents = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "little_check/documents")
        documents?.setMethodCallHandler { call, result ->
            if (call.method != "drain") { result.notImplemented(); return@setMethodCallHandler }
            val batch = pending.toList()
            pending.clear()
            worker.execute {
                val data = batch.map { readDocument(it) }
                runOnUiThread { if (!isDestroyed) result.success(data) }
            }
        }
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        if (intent.action == Intent.ACTION_VIEW) {
            pending.add(intent)
            documents?.invokeMethod("available", null)
        }
    }

    private fun readDocument(intent: Intent): Map<String, String> {
        return try {
            val uri = intent.data ?: throw IllegalArgumentException("没有可读取的文档")
            require(uri.scheme == "content" || uri.scheme == "file") { "不支持这个文档地址" }
            var name = uri.lastPathSegment ?: "外部笔记.md"
            if (uri.scheme == "content") {
                contentResolver.query(uri, arrayOf(OpenableColumns.DISPLAY_NAME), null, null, null)?.use { cursor ->
                    if (cursor.moveToFirst()) name = cursor.getString(0) ?: name
                }
            }
            val lower = name.lowercase()
            val type = intent.type ?: contentResolver.getType(uri)
            require(lower.endsWith(".md") || lower.endsWith(".markdown") || type == "text/markdown" || type == "text/x-markdown") { "请选择 .md 或 .markdown 文档" }
            val bytes = ByteArrayOutputStream()
            contentResolver.openInputStream(uri)?.use { input ->
                val buffer = ByteArray(8192)
                while (true) {
                    val count = input.read(buffer)
                    if (count < 0) break
                    require(bytes.size() + count <= 2 * 1024 * 1024) { "笔记超过 2 MiB，暂不支持导入" }
                    bytes.write(buffer, 0, count)
                }
            } ?: throw IllegalArgumentException("无法读取文档，请重新选择打开方式")
            val text = Charsets.UTF_8.newDecoder().onMalformedInput(CodingErrorAction.REPORT).onUnmappableCharacter(CodingErrorAction.REPORT).decode(ByteBuffer.wrap(bytes.toByteArray())).toString().removePrefix("\uFEFF")
            mapOf("name" to name, "content" to text)
        } catch (error: Exception) {
            mapOf("error" to (if (error is IllegalArgumentException) error.message ?: "无法导入文档" else "无法读取 UTF-8 文档，请检查格式和访问权限"))
        }
    }

    override fun onDestroy() {
        documents?.setMethodCallHandler(null)
        worker.shutdown()
        super.onDestroy()
    }
}

package com.merpyzf.data.helper.note_parse_helper

import android.content.Context
import android.net.Uri
import com.google.gson.GsonBuilder
import com.google.gson.JsonObject
import com.google.gson.JsonParser
import com.merpyzf.common.model.dto.api.SendBookDto
import com.merpyzf.common.model.vo.Book
import com.merpyzf.common.model.vo.Chapter
import com.merpyzf.common.model.vo.Group
import com.merpyzf.common.model.vo.Note
import com.merpyzf.common.model.vo.Review
import com.merpyzf.common.model.vo.Tag
import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.RuntimeEnvironment
import java.io.File
import java.math.BigDecimal
import java.nio.charset.StandardCharsets
import java.security.MessageDigest
import java.util.Locale
import java.util.TimeZone
import java.util.TreeMap
import java.util.zip.ZipInputStream

/**
 * 直接调用当前 Android :data 生产 Parser，把冻结输入转换为稳定 JSON；测试源码从 iOS 仓库注入，Android 工作树保持只读。
 */
@RunWith(RobolectricTestRunner::class)
class AndroidImportOracleTest {
    private val context: Context
        get() = RuntimeEnvironment.getApplication()

    /**
     * 固定 Locale/时区和附件传输结果，生成主样本与变异样本的 Android 生产输出。
     */
    @Test
    fun generateGoldenOutputs() {
        Locale.setDefault(Locale.SIMPLIFIED_CHINESE)
        TimeZone.setDefault(TimeZone.getTimeZone("Asia/Shanghai"))

        val fixtureRoot = requiredDirectory("IMPORT_ALIGNMENT_FIXTURE_ROOT")
        val outputRoot = requiredDirectory("IMPORT_ALIGNMENT_ORACLE_OUTPUT")
        processManifest(
            manifestFile = File(fixtureRoot, "manifest.json"),
            caseRoot = fixtureRoot,
            outputRoot = outputRoot
        )
        processManifest(
            manifestFile = File(fixtureRoot, "mutations/mutation-manifest.json"),
            caseRoot = File(fixtureRoot, "mutations"),
            outputRoot = File(outputRoot, "mutations")
        )
        assertTrue("Android Oracle 未生成任何输出", outputRoot.walkTopDown().any { it.isFile })
    }

    private fun processManifest(
        manifestFile: File,
        caseRoot: File,
        outputRoot: File
    ) {
        val manifest = JsonParser.parseString(manifestFile.readText()).asJsonObject
        manifest.getAsJsonArray("cases").forEach { element ->
            val item = element.asJsonObject
            val id = item.requiredString("id")
            val parserId = item.requiredString("parserId")
            val input = File(caseRoot, item.requiredString("input"))
            val expectedRelativePath = item.requiredString("expected")
            val output = File(outputRoot, expectedRelativePath)
            output.parentFile?.mkdirs()
            output.writeText(execute(parserId, input), StandardCharsets.UTF_8)
            println("ANDROID_IMPORT_ORACLE case=$id parser=$parserId output=${output.absolutePath}")
        }
    }

    private fun execute(parserId: String, input: File): String {
        val objectValue = try {
            sortedObject(
                "books" to parse(parserId, input).map(::bookObject),
                "schemaVersion" to 2,
                "status" to "success"
            )
        } catch (error: Throwable) {
            val mapped = mapError(parserId, error)
            sortedObject(
                "error" to sortedObject("code" to mapped.first, "message" to mapped.second),
                "schemaVersion" to 2,
                "status" to "failure"
            )
        }
        return GsonBuilder()
            .disableHtmlEscaping()
            .serializeNulls()
            .create()
            .toJson(objectValue) + "\n"
    }

    private fun parse(parserId: String, input: File): List<Book> {
        val content = input.readText(StandardCharsets.UTF_8)
        return when (parserId) {
            "boox-old" -> BooxParser(content).parse()
            "boox-new" -> NewBooxParser(content).parse()
            "douban-read" -> DoubanReadParser(context, content).doYourParse(content)
            "dedao" -> DedaoParser(content).parse()
            "dangdang" -> DangDangReadParser(content).parse()
            "dimo" -> runBlocking {
                DimoParser(context, content).apply {
                    noteImageTransfer = { sourceUrl ->
                        val digest = sha256(sourceUrl.toByteArray(StandardCharsets.UTF_8))
                        DimoImportedImage(
                            imageUrl = "fixture://uploaded/$digest.png",
                            digest = digest
                        )
                    }
                }.parseSuspend()
            }
            "weread-old" -> WeReadOldVersionParser(context, content).parse()
            "weread-pre-830" -> WeReadParser(context, content).parse()
            "weread-830" -> WeReadParserV830(context, content).parse()
            "duokan" -> DuoKanReadParser(context, content).parse()
            "ireader-selected" -> IReaderParser(context, content).parse()
            "moon-reader" -> MoonReadParser(context, content).parse()
            "douban-app" -> DoubanReadAppParser(context, content).parse()
            "reader-163" -> Reader163Parser(context, content).parse()
            "fanqie" -> FanQieParser(content).parse()
            "readingo" -> ReadingoParser(content).parse()
            "kindle-app" -> KindleAppParser(context, content).doYourParse(content)
            "koreader" -> KOReaderParser(context, content).doYourParse(content)
            "legado" -> LegadoParser(context, content).parse()
            "neat-reader" -> NeatReaderParser(context, content).parse()
            "koodo" -> KoodoParser(listOf(content)).parse()
            "reeden" -> ReedenParser(context, content).parse()
            "kindle" -> KindleParser(context, content).doYourParse(content)
            "jd-reader" -> JDReaderParser(context, content).doYourParse(content)
            "ireader-file" -> parseIReaderFile(input, content)
            "ireader-epub" -> {
                val directory = unzipFixture(input, "ireader")
                IReaderEBookParser(context, directory.absolutePath).parse()
            }
            "apple-books" -> {
                val directory = unzipFixture(input, "apple-books")
                val databaseDirectory = directory.walkTopDown().firstOrNull { candidate ->
                    candidate.isDirectory && candidate.listFiles().orEmpty().any { child ->
                        child.name.startsWith("AEAnnotation")
                    }
                } ?: directory
                AppleBooksParser(context, databaseDirectory.absolutePath).parse()
            }
            "hanwang" -> HanWangParser("汉王测试书", content).parse()
            else -> error("未接入 Android Oracle 的 Parser: $parserId")
        }
    }

    private fun parseIReaderFile(input: File, content: String): List<Book> {
        val parser = IReaderFreeNoteParser(context, Uri.fromFile(input).toString())
        val method = parser.javaClass.getDeclaredMethod("getBookName", String::class.java).apply {
            isAccessible = true
        }
        val bookName = method.invoke(parser, input.name) as String
        val field = parser.javaClass.getDeclaredField("bookName").apply { isAccessible = true }
        field.set(parser, bookName)
        if (bookName.isBlank()) throw parser.noteFormatException
        return parser.doYourParse(content.replace("\r", ""))
    }

    private fun unzipFixture(input: File, prefix: String): File {
        val directory = File.createTempFile("xmnote-$prefix-", ".oracle").also {
            check(it.delete())
            check(it.mkdirs())
        }
        val canonicalRoot = directory.canonicalFile
        ZipInputStream(input.inputStream().buffered()).use { archive ->
            while (true) {
                val entry = archive.nextEntry ?: break
                val destination = File(directory, entry.name).canonicalFile
                check(destination.path.startsWith(canonicalRoot.path + File.separator)) {
                    "非法 ZIP 路径: ${entry.name}"
                }
                if (entry.isDirectory) {
                    destination.mkdirs()
                } else {
                    destination.parentFile?.mkdirs()
                    destination.outputStream().use { archive.copyTo(it) }
                }
                archive.closeEntry()
            }
        }
        return directory
    }

    private fun bookObject(book: Book): Map<String, Any?> = sortedObject(
        "author" to book.author,
        "authorIntro" to book.authorIntro,
        "bookmarkModifiedTime" to book.bookmarkModifiedTime,
        "chapters" to (book.apiImportChapterList.ifEmpty { book.weReadChapterList }).map(::chapterObject),
        "cover" to book.cover,
        "currentPositionUnit" to book.currentPositionUnit,
        "doubanId" to book.doubanId,
        "fuzzyReadingDurations" to book.fuzzyReadingDurations?.map(::fuzzyDurationObject),
        "group" to book.group?.let(::groupObject),
        "groups" to book.groups.map(::groupObject),
        "isbn" to book.isbn,
        "name" to book.name,
        "notes" to book.noteList.map(::noteObject),
        "positionUnit" to book.positionUnit,
        "preciseReadingDurations" to book.preciseReadingDurations?.map(::preciseDurationObject),
        "press" to book.press,
        "pubDate" to book.pubDate,
        "rawName" to book.rawName,
        "readDoneTime" to book.readDoneTime,
        "readPosition" to decimal(book.readPosition),
        "readStatusChangedDate" to book.readStatusChangedDate,
        "readStatusId" to book.readStatusId,
        "reviews" to book.apiImportReviews.map(::reviewObject),
        "source" to book.source,
        "sourceName" to book.sourceName,
        "summary" to book.summary,
        "tags" to book.tags.map(::tagObject),
        "totalPagination" to book.totalPagination,
        "totalPosition" to book.totalPosition,
        "translator" to book.translator,
        "type" to book.type,
        "wereadBookId" to book.weReadBookId,
        "wereadUpdateTime" to book.wereadUpdateTime,
        "wordCount" to book.wordCount
    )

    private fun noteObject(note: Note): Map<String, Any?> = sortedObject(
        "attachments" to note.attachImages.mapIndexed { index, image ->
            sortedObject(
                "digest" to note.importAttachmentDigests.getOrNull(index).orEmpty(),
                "imageUrl" to image.imageUrl,
                "order" to image.order
            )
        },
        "chapter" to note.chapter.takeIf { it.title.isNotBlank() }?.let(::chapterObject),
        "content" to note.content,
        "createdTime" to note.createdDateTime,
        "idea" to note.idea,
        "isIncludeTime" to note.isIncludeTime,
        "position" to note.position,
        "positionUnit" to note.positionUnit,
        "tags" to note.tags.map(::tagObject),
        "wereadChapterUid" to note.wereadChapterUid,
        "wereadRange" to note.wereadRange
    )

    private fun chapterObject(chapter: Chapter): Map<String, Any?> = sortedObject(
        "children" to chapter.subChapterList.map(::chapterObject),
        "level" to chapter.level,
        "order" to chapter.order,
        "pathTitles" to chapter.pathTitles,
        "remark" to chapter.remark,
        "sourceAnchor" to chapter.sourceAnchor,
        "sourceOrder" to chapter.sourceOrder,
        "sourcePath" to chapter.sourcePath,
        "sourceType" to chapter.sourceType,
        "sourceUid" to chapter.sourceUid,
        "title" to chapter.title
    )

    private fun reviewObject(review: Review): Map<String, Any?> = sortedObject(
        "content" to review.content,
        "createdTime" to review.createdDateTime,
        "images" to review.images.map { image ->
            sortedObject("image" to image.image, "order" to image.order)
        },
        "title" to review.title
    )

    private fun groupObject(group: Group): Map<String, Any?> = sortedObject(
        "name" to group.name,
        "order" to group.order
    )

    private fun tagObject(tag: Tag): Map<String, Any?> = sortedObject(
        "color" to tag.color,
        "name" to tag.name,
        "order" to tag.order,
        "type" to tag.type
    )

    private fun preciseDurationObject(
        duration: SendBookDto.PreciseReadingDuration
    ): Map<String, Any?> = sortedObject(
        "endTime" to duration.endTime,
        "position" to duration.position?.let(::decimal),
        "startTime" to duration.startTime
    )

    private fun fuzzyDurationObject(
        duration: SendBookDto.FuzzyReadingDuration
    ): Map<String, Any?> = sortedObject(
        "date" to duration.date,
        "durationSeconds" to duration.durationSeconds,
        "position" to duration.position?.let(::decimal)
    )

    private fun mapError(parserId: String, original: Throwable): Pair<String, String> {
        val error = generateSequence(original) { it.cause }.last()
        val message = error.message.orEmpty()
        return when {
            message.contains("无法识别的数据库文件") ->
                "invalid_database" to "无法识别的数据库文件"
            message.contains("无法解析到书籍信息") ->
                "book_not_found" to "笔记格式有误，无法解析到书籍信息"
            message.contains("无法解析到书摘信息") ->
                "note_not_found" to "笔记格式有误，无法解析到书摘信息"
            message.contains("笔记格式有误") ->
                "note_format" to "笔记格式有误"
            parserId == "apple-books" ->
                "invalid_database" to "无法识别的数据库文件"
            parserId == "ireader-epub" ->
                "book_not_found" to "笔记格式有误，无法解析到书籍信息"
            else -> "unexpected" to message.ifBlank { error::class.java.simpleName }
        }
    }

    private fun requiredDirectory(environmentName: String): File {
        val path = System.getenv(environmentName)
            ?: error("$environmentName 未设置")
        return File(path).also {
            check(it.isDirectory || it.mkdirs()) { "$environmentName 不是可用目录: $path" }
        }
    }

    private fun JsonObject.requiredString(name: String): String =
        get(name)?.asString ?: error("manifest 缺少 $name")

    private fun sortedObject(vararg pairs: Pair<String, Any?>): Map<String, Any?> =
        TreeMap<String, Any?>().apply { pairs.forEach { put(it.first, it.second) } }

    private fun decimal(value: Double): String =
        BigDecimal.valueOf(value).stripTrailingZeros().toPlainString()

    private fun sha256(data: ByteArray): String =
        MessageDigest.getInstance("SHA-256")
            .digest(data)
            .joinToString("") { byte -> "%02x".format(byte) }
}

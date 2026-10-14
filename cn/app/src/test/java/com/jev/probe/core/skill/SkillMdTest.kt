package com.jev.probe.core.skill

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/** The `---` frontmatter reader, and the validation the specification demands. */
class SkillMdTest {

    private fun md(front: String, body: String = "正文步骤") = "---\n$front\n---\n$body"

    @Test
    fun parsesTheCanonicalShape() {
        val parsed = SkillMd.parse(
            md(
                """
                name: pdf-fill
                description: 填写 PDF 表单时使用。当用户给来一份可填写的 PDF。
                license: Apache-2.0
                compatibility: 需要 pdfbox
                allowed-tools: read write
                metadata:
                  author: emo
                  version: "2"
                """.trimIndent()
            )
        )
        assertNotNull(parsed)
        val (fm, body) = parsed!!
        assertEquals("pdf-fill", fm.name)
        assertTrue(fm.description.startsWith("填写 PDF 表单"))
        assertEquals("Apache-2.0", fm.license)
        assertEquals("需要 pdfbox", fm.compatibility)
        assertEquals("read write", fm.allowedTools)
        assertEquals("emo", fm.metadata["author"])
        assertEquals("2", fm.metadata["version"])
        assertEquals("正文步骤", body)
    }

    @Test
    fun bodyKeepsInternalBlankLines() {
        val parsed = SkillMd.parse(md("name: a-b\ndescription: x 时使用", "第一步\n\n第二步"))!!
        assertEquals("第一步\n\n第二步", parsed.second)
    }

    @Test
    fun crlfIsNormalised() {
        val parsed = SkillMd.parse("---\r\nname: a-b\r\ndescription: x 时使用\r\n---\r\nbody")
        assertNotNull(parsed)
        assertEquals("body", parsed!!.second)
    }

    @Test
    fun aDescriptionWithAColonSurvives() {
        val parsed = SkillMd.parse(md("name: a-b\ndescription: note: 写周报时使用"))!!
        assertEquals("note: 写周报时使用", parsed.first.description)
    }

    @Test
    fun quotedScalarsAreUnquoted() {
        val parsed = SkillMd.parse(md("name: a-b\ndescription: \"带引号的说明，写周报时使用\""))!!
        assertEquals("带引号的说明，写周报时使用", parsed.first.description)
    }

    @Test
    fun missingFrontmatterIsNull() {
        assertNull(SkillMd.parse("name: a-b\ndescription: 说明"))
        assertNull(SkillMd.parse(""))
    }

    @Test
    fun unterminatedFrontmatterIsNull() {
        assertNull(SkillMd.parse("---\nname: a-b\ndescription: 写周报时使用\nbody"))
    }

    @Test
    fun descriptionIsRequired() {
        assertNull(SkillMd.parse(md("name: a-b")))
        assertNull(SkillMd.parse(md("name: a-b\ndescription: 　")))
    }

    @Test
    fun oversizedFieldsAreRejected() {
        assertNull(SkillMd.parse(md("name: a-b\ndescription: " + "x".repeat(SkillMd.DESCRIPTION_MAX + 1))))
        assertNull(
            SkillMd.parse(
                md("name: a-b\ndescription: 写周报时使用\ncompatibility: " + "x".repeat(SkillMd.COMPATIBILITY_MAX + 1))
            )
        )
    }

    @Test
    fun badNamesAreRejected() {
        assertNull(SkillMd.parse(md("name: Pdf-Fill\ndescription: 写周报时使用")))   // uppercase
        assertNull(SkillMd.parse(md("name: -abc\ndescription: 写周报时使用")))       // leading hyphen
        assertNull(SkillMd.parse(md("name: a--b\ndescription: 写周报时使用")))       // doubled hyphen
        assertNull(SkillMd.parse(md("name: a_b\ndescription: 写周报时使用")))        // underscore
        assertNull(SkillMd.parse(md("name: " + "a".repeat(SkillMd.NAME_MAX + 1) + "\ndescription: 写周报时使用")))
    }

    @Test
    fun validNameMatchesTheSpecification() {
        assertTrue(SkillMd.validName("pdf-fill"))
        assertTrue(SkillMd.validName("a"))
        assertTrue(SkillMd.validName("a1-b2-c3"))
        assertTrue(!SkillMd.validName("PDF-fill"))
        assertTrue(!SkillMd.validName("pdf fill"))
        assertTrue(!SkillMd.validName(""))
    }
}

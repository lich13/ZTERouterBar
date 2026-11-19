package com.zte.routerbar.core

import org.junit.Assert.assertEquals
import org.junit.Test

class RouterCryptoTest {
    @Test
    fun sha256UppercaseAndLoginChallengeMatchZteUtilJs() {
        assertEquals(
            "BA7816BF8F01CFEA414140DE5DAE2223B00361A396177A9CB410FF61F20015AD",
            RouterCrypto.sha256Upper("abc")
        )

        val pwHash = RouterCrypto.sha256Upper("demo-password")
        val challenge = RouterCrypto.computeLoginPassword(plainPassword = "demo-password", ld = "SALT123")
        assertEquals(RouterCrypto.sha256Upper(pwHash + "SALT123"), challenge)

        val adSha = RouterCrypto.computeAD(
            waInnerVersion = "BD_FLYMODEMMU5120V1.0.1B12",
            crVersion = "",
            rd = "RAND456",
            algorithm = ResolvedHashAlgorithm.SHA256
        )
        assertEquals(
            RouterCrypto.sha256Upper(RouterCrypto.sha256Upper("BD_FLYMODEMMU5120V1.0.1B12") + "RAND456"),
            adSha
        )

        val adMd5 = RouterCrypto.computeAD(
            waInnerVersion = "BD_MC801AV1.0.0",
            crVersion = "CR1",
            rd = "RD1",
            algorithm = ResolvedHashAlgorithm.MD5
        )
        assertEquals(32, adMd5.length)
        assertEquals(adMd5.lowercase(), adMd5)

        assertEquals(
            ResolvedHashAlgorithm.SHA256,
            ResolvedHashAlgorithm.resolve("BD_FLYMODEMMU5120V1.0.1B12", AuthHashPreference.AUTO)
        )
        assertEquals(
            ResolvedHashAlgorithm.MD5,
            ResolvedHashAlgorithm.resolve("BD_MC801AV1.0.0B01", AuthHashPreference.AUTO)
        )
        assertEquals(
            ResolvedHashAlgorithm.MD5,
            ResolvedHashAlgorithm.resolve("BD_MF286DV1.0.0", AuthHashPreference.AUTO)
        )
    }
}

package com.jev.probe.overlay

import com.jev.probe.core.RankedReply

/**
 * Single semantic state for overlay lifecycle. The legacy view references remain
 * inside OverlayController because the custom WindowManager view is incremental;
 * all externally visible phase changes now pass through this state.
 */
sealed interface OverlayUiState {
    data object Idle : OverlayUiState
    data object Loading : OverlayUiState
    data class Draft(val replies: List<RankedReply>) : OverlayUiState
    data class Ranked(val replies: List<RankedReply>) : OverlayUiState
    data class Error(val message: String) : OverlayUiState
}

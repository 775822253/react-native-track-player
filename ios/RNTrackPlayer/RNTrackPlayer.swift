//
//  RNTrackPlayer.swift
//  RNTrackPlayer
//
//  Created by David Chavez on 13.08.17.
//  Copyright © 2017 David Chavez. All rights reserved.
//

import Foundation
import MediaPlayer
import SwiftAudioEx
import AVFoundation

@objc(RNTrackPlayer)
public class RNTrackPlayer: RCTEventEmitter, AudioSessionControllerDelegate {

    // MARK: - Attributes

    private var hasInitialized = false
    private let player = QueuedAudioPlayer()
    private let audioSessionController = AudioSessionController.shared
    private var shouldEmitProgressEvent: Bool = false
    private var shouldResumePlaybackAfterInterruptionEnds: Bool = false
    private var forwardJumpInterval: NSNumber? = nil;
    private var backwardJumpInterval: NSNumber? = nil;
    private var sessionCategory: AVAudioSession.Category = .playback
    private var sessionCategoryMode: AVAudioSession.Mode = .default
    private var sessionCategoryPolicy: AVAudioSession.RouteSharingPolicy = .default
    private var sessionCategoryOptions: AVAudioSession.CategoryOptions = []
    
    // 修复：使用串行队列代替 NSLock
    private let playerQueue = DispatchQueue(label: "RNTrackPlayer.player.queue", qos: .userInitiated)
    
    // 修复：增强请求管理，支持延迟处理
    private var currentRequestMap: [String: Bool] = [:]
    private let requestLock = NSLock()
    
    // 新增：状态标记
    private var isPlayerInErrorState: Bool = false
    
    // 新增：重试机制
    private var retryCount: Int = 0
    private let maxRetryCount: Int = 2
    private var isRetrying: Bool = false
    private var currentRetryTask: DispatchWorkItem?
    
    // 新增：切换操作状态管理
    private var isSwitchingTrack: Bool = false
    private var pendingSwitchIndex: Int? = nil
    private var lastSwitchTime: Date = Date.distantPast
    private let switchDebounceInterval: TimeInterval = 0.1 // 100ms防抖
    
    // 新增：跟踪播放状态，防止状态混乱
    private var currentPlaybackPosition: [Int: Double] = [:]
    private var lastValidPosition: Double = 0
    private var isSeeking: Bool = false
    
    // 首先，在类中添加一个新的属性来保存切换前的播放状态
    // 在类的属性部分添加：
    private var wasPlayingBeforeSwitch: Bool = false
    
    // 在类中添加属性记录重试开始时间
    private var lastRetryStartTime: Date = Date()
    
    // MARK: - Lifecycle Methods

    public override init() {
        super.init()
        EventEmitter.shared.register(eventEmitter: self)
        audioSessionController.delegate = self
        player.playWhenReady = false;
        
        // 修复：配置更稳定的播放器参数
        configurePlayerForStability()
        
        // 修复：在主队列中设置监听器，确保线程安全
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            
            self.player.event.receiveChapterMetadata.addListener(self, handleAudioPlayerChapterMetadataReceived)
            self.player.event.receiveTimedMetadata.addListener(self, handleAudioPlayerTimedMetadataReceived)
            self.player.event.receiveCommonMetadata.addListener(self, handleAudioPlayerCommonMetadataReceived)
            self.player.event.stateChange.addListener(self, handleAudioPlayerStateChange)
            self.player.event.fail.addListener(self, handleAudioPlayerFailed)
            self.player.event.currentItem.addListener(self, handleAudioPlayerCurrentItemChange)
            self.player.event.secondElapse.addListener(self, handleAudioPlayerSecondElapse)
            // 修复：使用正确的事件名称
            self.player.event.playWhenReadyChange.addListener(self, handlePlayWhenReadyChange)
            self.player.event.didRecreateAVPlayer.addListener(self, handleAVPlayerRecreated)
            
            // 修复：修正seek事件的监听器参数类型
            self.player.event.seek.addListener(self) { [weak self] (eventData: AudioPlayer.SeekEventData) in
                self?.handleSeekEvent(eventData: eventData)
            }
        }
    }

    deinit {
        // 修复：在 deinit 时正确清理
        playerQueue.async { [weak player] in
            player?.stop()
            player?.clear()
        }
        cancelCurrentRetry()
    }
    
    // 修复：配置播放器以提高稳定性
    private func configurePlayerForStability() {
        // 设置较大的缓冲区
        player.bufferDuration = 30
        // 启用自动等待缓冲区
        player.automaticallyWaitsToMinimizeStalling = true
        // 禁用自动调整播放速率
        player.automaticallyUpdateNowPlayingInfo = true
        // 设置播放器行为
        player.volume = 1.0
        player.rate = 1.0
    }
    
    // 修复：修正handleSeekEvent方法的参数类型
    private func handleSeekEvent(eventData: AudioPlayer.SeekEventData) {
        playerQueue.async { [weak self] in
            guard let self = self else { return }
            
            let currentIndex = self.player.currentIndex
            if currentIndex >= 0 {
                self.currentPlaybackPosition[currentIndex] = eventData.seconds
                self.lastValidPosition = eventData.seconds
            }
        }
    }
    
    // 新增：处理播放中途失败，自动跳转到下一首
    private func handlePlaybackMidwayFailure(error: Error) {
        playerQueue.async { [weak self] in
            guard let self = self else { return }
            
            let currentIndex = self.player.currentIndex
            if currentIndex < 0 { return }
            
            // 所有错误都重试
            print("Playback midway failure, attempting retry (max \(self.maxRetryCount) times)...")
            self.retryPlaybackWithDelay()
        }
    }
    
    // 新增：自动跳转到下一首可播放曲目
    private func autoSkipToNextPlayableTrack() {
        let currentIndex = player.currentIndex
        if currentIndex < 0 { return }
        
        // 先记录失败
//        recordFailure(at: currentIndex)
        
        let nextValidIndex = findNextPlayableTrack(from: currentIndex)
        if let nextValidIndex = nextValidIndex {
            print("Auto-skipping from track \(currentIndex) to track \(nextValidIndex)")
            
            // 关键修复：保存当前播放状态，因为切换后可能会被重置
            let wasPlaying = self.wasPlayingBeforeSwitch || player.playerState == .playing
            print("Auto-skip: wasPlaying=\(wasPlaying)")
            
            // 关键修复：设置切换前的播放状态，确保自动跳转后能保持播放
            self.wasPlayingBeforeSwitch = wasPlaying
            
            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }
                
                self.emit(event: EventType.PlaybackError, body: [
                    "error": "播放失败，已自动跳转到下一首",
                    "code": "auto_skip_on_failure",
                    "skippedIndex": currentIndex,
                    "newIndex": nextValidIndex
                ])
                
                
                
                // 自动切换并播放
                self.performSmartSwitch(to: nextValidIndex, initialTime: 0, isNext: true,
                                      resolve: { _ in }, reject: { _, _, _ in })
            }
        } else {
            print("No playable track found after auto-skip")
            
            DispatchQueue.main.async { [weak self] in
                self?.emit(event: EventType.PlaybackError, body: [
                    "error": "播放失败，且没有其他可播放曲目",
                    "code": "no_playable_track_after_failure"
                ])
            }
        }
    }
    
    // 新增：智能切换轨道方法（增强版）
    private func performSmartSwitch(to index: Int, initialTime: Double, isNext: Bool, resolve: @escaping RCTPromiseResolveBlock, reject: @escaping RCTPromiseRejectBlock) {
        let now = Date()
        let timeSinceLastSwitch = now.timeIntervalSince(lastSwitchTime)
        
        // 检查是否正在切换且距离上次切换时间很短
        if isSwitchingTrack && timeSinceLastSwitch < switchDebounceInterval {
            print("Switch in progress, skipping duplicate request")
            // 记录待处理的切换请求（只保留最新的）
            pendingSwitchIndex = index
            DispatchQueue.main.async {
                resolve(NSNull()) // 立即返回成功，避免RN端阻塞
            }
            return
        }
        
        // 检查是否正在重试
        if isRetrying {
            print("Cancelling retry due to track switch request")
            cancelCurrentRetry()
        }
        
        // 标记开始切换
        isSwitchingTrack = true
        lastSwitchTime = now
        pendingSwitchIndex = nil
        
        playerQueue.async { [weak self] in
            guard let self = self else {
                DispatchQueue.main.async {
                    reject("player_error", "Player is not available", nil)
                }
                return
            }
            
            // 检查播放器是否处于错误状态
            if self.isPlayerInErrorState {
                // 重置错误状态并继续
                self.isPlayerInErrorState = false
                print("Resetting error state for track switch")
            }
            
            // 检查索引范围
            if index < 0 || index >= self.player.items.count {
                self.isSwitchingTrack = false
                DispatchQueue.main.async {
                    reject("index_out_of_bounds", "The track index is out of bounds", nil)
                }
                return
            }
            
            // 关键修复：在切换前确保AVPlayer状态正确重置
            self.resetPlayerStateBeforeSwitch()
            
            // 决定实际的初始播放时间
            var actualInitialTime = initialTime
            
            // 如果是非下一首操作（如直接跳转到某首），使用指定的initialTime
            // 如果是下一首操作，应该从0开始，除非有特殊需求
            if isNext && initialTime < 0 {
                actualInitialTime = 0
            }
            
            do {
                // 关键修复：根据当前播放状态决定是否在新曲目上播放
                // 如果是切换操作（下一首/上一首），保持原来的播放状态
                // 如果是直接跳转到某首，使用默认的播放逻辑
                let currentPlayerState = self.player.playerState
                let isCurrentlyPlaying = currentPlayerState == .playing
                let shouldPlay = isNext ? self.player.playWhenReady : (self.player.playerState == .playing || self.player.playWhenReady)
                
                print("Switching to track \(index), current state: \(currentPlayerState), isPlaying: \(isCurrentlyPlaying), shouldPlay: \(shouldPlay), initialTime: \(actualInitialTime)")
                
                // 使用增强的安全跳转方法
                try self.enhancedJumpToItem(atIndex: index, playWhenReady: shouldPlay, initialTime: actualInitialTime)
                
                // 重置重试计数（切换到新曲目应该重新开始重试机会）
                self.resetRetryState()
                
                // 标记切换完成
                self.isSwitchingTrack = false
                
                // 检查是否有待处理的切换请求
                if let pendingIndex = self.pendingSwitchIndex {
                    print("Processing pending switch to index \(pendingIndex)")
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                        self.performSmartSwitch(to: pendingIndex, initialTime: actualInitialTime, isNext: isNext, resolve: resolve, reject: reject)
                    }
                } else {
                    DispatchQueue.main.async {
                        resolve(NSNull())
                    }
                }
                
            } catch {
                self.isSwitchingTrack = false
                print("Failed to switch track: \(error)")
                
                let errorMessage = error.localizedDescription
                
                // 如果是切换操作，尝试自动跳过有问题的曲目
                if isNext {
                    // 尝试找下一首可播放的曲目
                    let nextValidIndex = self.findNextPlayableTrack(from: index)
                    if let nextValidIndex = nextValidIndex {
                        DispatchQueue.main.async {
                            self.emit(event: EventType.PlaybackError, body: [
                                "error": "曲目无法播放，已自动跳过",
                                "code": "track_unplayable_auto_skipped",
                                "skippedIndex": index,
                                "newIndex": nextValidIndex
                            ])
                            
                            // 自动切换到下一首可播放的曲目
                            self.performSmartSwitch(to: nextValidIndex, initialTime: 0, isNext: true, resolve: resolve, reject: reject)
                        }
                        return
                    }
                }
                
                // 直接切换到该曲目失败，发送错误但继续允许操作
                DispatchQueue.main.async {
                    self.emit(event: EventType.PlaybackError, body: [
                        "error": "当前曲目无法播放",
                        "code": "track_unplayable",
                        "originalError": errorMessage,
                        "trackIndex": index
                    ])
                    
                    // 仍然返回成功，因为切换操作本身成功了（虽然曲目无法播放）
                    resolve(NSNull())
                }
            }
        }
    }
    
    // 新增：在切换前重置播放器状态
    private func resetPlayerStateBeforeSwitch() {
        
        // 保存当前是否在播放的状态
        wasPlayingBeforeSwitch = player.playerState == .playing
        
        // 重置seek状态
        isSeeking = false
        
        // 只有在播放器处于错误状态时才重新加载
        if player.playerState == .failed || player.playerState == .stopped {
            do {
                try player.reload(startFromCurrentTime: false)
            } catch {
                print("Failed to reload player before switch: \(error)")
            }
        }
    }
    
    // 新增：增强的安全跳转方法
    private func enhancedJumpToItem(atIndex index: Int, playWhenReady: Bool, initialTime: Double) throws {
        // 先暂停当前播放（如果正在播放）
//        let wasPlaying = player.playerState == .playing
//        
//        if wasPlaying {
//            player.pause()
//        }
        
        // 关键修复：确保AVPlayer状态正确
        // 等待一小段时间让AVPlayer稳定
        Thread.sleep(forTimeInterval: 0.05)
        
        // 执行跳转
        try player.jumpToItem(atIndex: index, playWhenReady: playWhenReady)
        
        // 关键修复：确保切换到新曲目后从正确的位置开始
        // 等待AVPlayerItem加载完成
        if initialTime >= 0 {
            // 延迟一小段时间，确保AVPlayerItem已经准备好
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
                guard let self = self else { return }
                
                self.playerQueue.async {
                    // 再次检查当前曲目是否仍然是目标曲目
                    if self.player.currentIndex == index {
                        self.player.seek(to: initialTime)
                        print("Seeked to initial time: \(initialTime) for track \(index)")
                        
                        // 记录当前位置
                        self.currentPlaybackPosition[index] = initialTime
                        self.lastValidPosition = initialTime
                    }
                }
            }
        }
        
        // 如果要求播放，等待一小段时间后播放
        if playWhenReady {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                self.playerQueue.async {
                    do {
                        // 再次检查是否仍然是目标曲目
                        if self.player.currentIndex == index {
                            try self.player.play()
                            print("Started/resumed playback for track \(index)")
                        }
                    } catch {
                        print("Failed to start/resume playback after switch: \(error)")
                    }
                }
            }
        }
    }
    
    // 新增：查找下一首可播放的曲目
    private func findNextPlayableTrack(from currentIndex: Int) -> Int? {
        let totalTracks = player.items.count
        
        // 从当前索引+1开始查找
        for i in (currentIndex + 1)..<totalTracks {
            return i
        }
        
        // 如果后面没有，从开头查找
        for i in 0..<currentIndex {
            return i
        }
        
        return nil
    }
    
    // 新增：取消当前重试
    private func cancelCurrentRetry() {
        isRetrying = false
        currentRetryTask?.cancel()
        currentRetryTask = nil
        print("Retry cancelled")
    }
    
    // 新增：重试播放的方法
    private func retryPlaybackWithDelay() {
        // 更新重试开始时间
        lastRetryStartTime = Date()
        // 安全检查
        if !checkRetrySafety() {
            return
        }
        // 取消之前的重试任务
        currentRetryTask?.cancel()
        
        // 检查是否正在切换曲目，如果是则取消重试
        if isSwitchingTrack {
            print("Skipping retry because track is switching")
            resetRetryState()
            return
        }
        
        // 增加重试计数
        retryCount += 1
        isRetrying = true
        
        // 检查是否最近失败过
        let currentIndex = player.currentIndex
        
        // 标记播放器处于错误状态（关键修复：这会阻止进度更新）
        isPlayerInErrorState = true
        
        print("开始重试 track \(currentIndex) - 第 \(retryCount) 次/共 \(maxRetryCount) 次")
        
        // 如果已经达到最大重试次数，报错给RN并尝试自动跳过
        if retryCount > maxRetryCount {
            print("已达到最大重试次数 (\(maxRetryCount)次)，尝试自动跳过")
            
            DispatchQueue.main.async { [weak self] in
                // 修复：明确使用self.maxRetryCount
                self?.emit(event: EventType.PlaybackError, body: [
                    "error": "播放失败，已达到最大重试次数 (\(self?.maxRetryCount ?? 5))",
                    "code": "max_retry_exceeded",
                    "retryCount": self?.retryCount ?? 0,
                    "trackIndex": currentIndex
                ])
            }
            
            // 自动跳转到下一首
            autoSkipToNextPlayableTrack()
            
            // 重置重试状态
            resetRetryState()
            return
        }
        
        
        print("开始第 \(retryCount)/\(maxRetryCount) 次重试")
        
        // 计算延迟时间（固定策略，避免过长等待）
        // 第1次：0.3秒，第2次：0.5秒，第3次：1秒，第4次：2秒，第5次：3秒
        let delays: [TimeInterval] = [1.0, 2.0, 3.0, 4.0, 5.0]
        let delayIndex = min(retryCount - 1, delays.count - 1)
        let delay = delays[delayIndex]
        
        // 创建重试任务
        let retryTask = DispatchWorkItem { [weak self] in
            guard let self = self else { return }
            
            // 再次检查是否仍在重试状态（可能被取消）
            if !self.isRetrying {
                print("Retry cancelled before execution")
                return
            }
            
            // 检查是否正在切换曲目
            if self.isSwitchingTrack {
                print("Skipping retry during track switch")
                self.resetRetryState()
                return
            }
            
            self.playerQueue.async {
                do {
                    
                    print("执行第 \(self.retryCount)/\(self.maxRetryCount) 次重试操作...")
                    
                    // 关键修复：在尝试重试前，重置错误状态
                    self.isPlayerInErrorState = false
                    
                    // 关键修复：检查播放器当前状态
                    let currentState = self.player.playerState
                    print("当前播放器状态: \(currentState)")
                    
                    // 如果播放器已经在播放状态，无需重试
                    if currentState == .playing {
                        print("播放器已经在播放状态，重试成功")
                        self.resetRetryState()
                        return
                    }
                    
                    // 如果播放器已经失败或停止，尝试重新加载
                    if currentState == .failed || currentState == .stopped {
                        print("播放器处于失败状态，尝试重新加载...")
                        try self.player.reload(startFromCurrentTime: false)
                    }
                    
                    
                    // 等待一小段时间让播放器稳定
                    Thread.sleep(forTimeInterval: 0.3)
                    let newState = self.player.playerState
                    
                    // 如果播放器之前是播放状态，尝试恢复播放
                    if newState == .ready || newState == .buffering {
//                        self.player.playWhenReady = true
                        try self.player.play()
                        print("第 \(self.retryCount)/\(self.maxRetryCount) 次重试成功！")
                        
                        // 再次检查播放后的状态
                        Thread.sleep(forTimeInterval: 0.1)
                        let finalState = self.player.playerState
                        
                        if finalState == .playing || finalState == .buffering {
                            print("第 \(self.retryCount)/\(self.maxRetryCount) 次重试成功！")
                            self.resetRetryState()
                        } else {
                            // 播放失败，再次重置 playWhenReady
//                            self.player.playWhenReady = false
                            print("第 \(self.retryCount)/\(self.maxRetryCount) 次重试失败：播放后状态为 \(finalState)")
                            self.isPlayerInErrorState = true
                        }
                        self.isRetrying = false
                    } else {
                        print("第 \(self.retryCount)/\(self.maxRetryCount) 次重试不成功")
                        self.isPlayerInErrorState = true
                        self.isRetrying = false
                    }
                    
                } catch {
                    print("Retry failed on attempt \(self.retryCount): \(error)")
                    
                    // 关键修复：重试失败时，重新标记为错误状态
                    self.isPlayerInErrorState = true
//                    self.player.playWhenReady = false
                    
                    // 检查是否需要继续重试
                    if self.retryCount < self.maxRetryCount {
                        print("将在 \(delay) 秒后进行第 \(self.retryCount + 1)/\(self.maxRetryCount) 次重试...")
                        self.isRetrying = false
                        // 如果重试失败，继续重试
                        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                            self.retryPlaybackWithDelay()
                        }
                    } else {
                        // 达到最大重试次数
                        let errorMessage = error.localizedDescription
                        
                        DispatchQueue.main.async {
                            self.emit(event: EventType.PlaybackError, body: [
                                "error": errorMessage,
                                "code": "max_retry_exceeded",
                                "retryCount": self.retryCount,
                                "trackIndex": self.player.currentIndex
                            ])
                        }
                        self.isRetrying = false
                        
                        // 自动跳转到下一首
                        self.autoSkipToNextPlayableTrack()
                        
                        self.resetRetryState()
                    }
                }
            }
        }
        
        currentRetryTask = retryTask
        
        // 延迟执行重试
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: retryTask)
    }
    
    // 新增：重置重试状态
    private func resetRetryState() {
        retryCount = 0
        isRetrying = false
        isPlayerInErrorState = false  // 关键修复：重置错误状态
        currentRetryTask?.cancel()
        currentRetryTask = nil
    }
    
    // 新增：重置播放器错误状态
    private func resetPlayerErrorState() {
        playerQueue.async { [weak self] in
            guard let self = self else { return }
            
            // 重置错误状态标记
            self.isPlayerInErrorState = false
            
            // 重置重试状态
            self.resetRetryState()
            
            // 重置切换状态
            self.isSwitchingTrack = false
            self.pendingSwitchIndex = nil
            
            // 重置seek状态
            self.isSeeking = false
            
            // 尝试重置播放器状态
            do {
                // 如果当前处于错误状态，尝试重新加载
                if self.player.playerState == .failed {
                    try self.player.reload(startFromCurrentTime: false)
                }
            } catch {
                print("Failed to reset player error state: \(error)")
            }
        }
    }

    // MARK: - RCTEventEmitter

    override public static func requiresMainQueueSetup() -> Bool {
        return true;
    }

    @objc(constantsToExport)
    override public func constantsToExport() -> [AnyHashable: Any] {
        return [
            "STATE_NONE": State.none.rawValue,
            "STATE_READY": State.ready.rawValue,
            "STATE_PLAYING": State.playing.rawValue,
            "STATE_PAUSED": State.paused.rawValue,
            "STATE_STOPPED": State.stopped.rawValue,
            "STATE_BUFFERING": State.buffering.rawValue,
            "STATE_LOADING": State.loading.rawValue,
            "STATE_ERROR": State.error.rawValue,

            "TRACK_PLAYBACK_ENDED_REASON_END": PlaybackEndedReason.playedUntilEnd.rawValue,
            "TRACK_PLAYBACK_ENDED_REASON_JUMPED": PlaybackEndedReason.jumpedToIndex.rawValue,
            "TRACK_PLAYBACK_ENDED_REASON_NEXT": PlaybackEndedReason.skippedToNext.rawValue,
            "TRACK_PLAYBACK_ENDED_REASON_PREVIOUS": PlaybackEndedReason.skippedToPrevious.rawValue,
            "TRACK_PLAYBACK_ENDED_REASON_STOPPED": PlaybackEndedReason.playerStopped.rawValue,

            "PITCH_ALGORITHM_LINEAR": PitchAlgorithm.linear.rawValue,
            "PITCH_ALGORITHM_MUSIC": PitchAlgorithm.music.rawValue,
            "PITCH_ALGORITHM_VOICE": PitchAlgorithm.voice.rawValue,

            "CAPABILITY_PLAY": Capability.play.rawValue,
            "CAPABILITY_PLAY_FROM_ID": "NOOP",
            "CAPABILITY_PLAY_FROM_SEARCH": "NOOP",
            "CAPABILITY_PAUSE": Capability.pause.rawValue,
            "CAPABILITY_STOP": Capability.stop.rawValue,
            "CAPABILITY_SEEK_TO": Capability.seek.rawValue,
            "CAPABILITY_SKIP": "NOOP",
            "CAPABILITY_SKIP_TO_NEXT": Capability.next.rawValue,
            "CAPABILITY_SKIP_TO_PREVIOUS": Capability.previous.rawValue,
            "CAPABILITY_SET_RATING": "NOOP",
            "CAPABILITY_JUMP_FORWARD": Capability.jumpForward.rawValue,
            "CAPABILITY_JUMP_BACKWARD": Capability.jumpBackward.rawValue,
            "CAPABILITY_LIKE": Capability.like.rawValue,
            "CAPABILITY_DISLIKE": Capability.dislike.rawValue,
            "CAPABILITY_BOOKMARK": Capability.bookmark.rawValue,

            "REPEAT_OFF": RepeatMode.off.rawValue,
            "REPEAT_TRACK": RepeatMode.track.rawValue,
            "REPEAT_QUEUE": RepeatMode.queue.rawValue,
        ]
    }

    @objc(supportedEvents)
    override public func supportedEvents() -> [String] {
        return EventType.allRawValues()
    }

    private func emit(event: EventType, body: Any? = nil) {
        DispatchQueue.main.async {
            EventEmitter.shared.emit(event: event, body: body)
        }
    }

    // MARK: - AudioSessionControllerDelegate

    public func handleInterruption(type: InterruptionType) {
        playerQueue.async { [weak self] in
            guard let self = self else { return }
            
            switch type {
            case .began:
                self.emit(event: EventType.RemoteDuck, body: [
                    "paused": true
                ])
            case let .ended(shouldResume):
                if shouldResume {
                    if self.shouldResumePlaybackAfterInterruptionEnds {
                        do {
                            try self.player.play()
                        } catch {
                            print("Failed to resume playback after interruption: \(error)")
                        }
                    }
                    self.emit(event: EventType.RemoteDuck, body: [
                        "paused": false
                    ])
                } else {
                    self.emit(event: EventType.RemoteDuck, body: [
                        "paused": true,
                        "permanent": true
                    ])
                }
            }
        }
    }

    // MARK: - AudioSession 管理（核心修复）

    private func configureAudioSession() {
        do {
            let session = AVAudioSession.sharedInstance()
            if #available(iOS 11.0, *) {
                try session.setCategory(
                    sessionCategory,
                    mode: sessionCategoryMode,
                    policy: sessionCategoryPolicy,
                    options: sessionCategoryOptions
                )
            } else {
                try session.setCategory(
                    sessionCategory,
                    mode: sessionCategoryMode,
                    options: sessionCategoryOptions
                )
            }

            // 修复：只在有播放意图时激活，不依赖 currentItem
            if player.playWhenReady {
                try audioSessionController.activateSession()
            }
            
            // 修复：即使 currentItem == nil，也不停用 session
            // 让 session 保持激活状态直到 reset 或 deinit
            
        } catch {
            print("AudioSession configuration error:", error)
            // 不抛出错误，避免影响播放
        }
    }
    
    private func deactivateAudioSession() {
        do {
            try audioSessionController.deactivateSession()
        } catch {
            print("AudioSession deactivation error:", error)
        }
    }

    // MARK: - 辅助方法

    private func rejectWhenNotInitialized(reject: RCTPromiseRejectBlock) -> Bool {
        let rejected = !hasInitialized;
        if (rejected) {
            reject("player_not_initialized", "The player is not initialized. Call setupPlayer first.", nil)
        }
        return rejected;
    }

    // 修复：移除 playerQueue.sync，避免死锁
    private func rejectWhenTrackIndexOutOfBounds(
        index: Int,
        min: Int? = nil,
        max : Int? = nil,
        message : String? = "The track index is out of bounds",
        reject: RCTPromiseRejectBlock
    ) -> Bool {
        // 注意：这里不能使用 playerQueue.sync，因为可能在 playerQueue 中调用
        // 改为直接访问，因为我们已经确保在适当的上下文中调用
        let itemCount = player.items.count
        let actualMax = max ?? (itemCount == 0 ? 0 : itemCount - 1)
        let rejected = index < (min ?? 0) || index > actualMax
        
        if (rejected) {
            reject("index_out_of_bounds", message, nil)
        }
        return rejected
    }
    
    // 修复：检查请求是否已经在处理中
    private func beginRequest(_ key: String) -> Bool {
        requestLock.lock()
        defer { requestLock.unlock() }
        
        if currentRequestMap[key] == true {
            return false
        }
        
        currentRequestMap[key] = true
        return true
    }
    
    private func endRequest(_ key: String) {
        requestLock.lock()
        defer { requestLock.unlock() }
        
        currentRequestMap[key] = nil
    }
    
    // 修复：从 MediaURL 获取 URL
    private func getURLFromMediaURL(_ mediaURL: MediaURL) -> URL? {
        // 使用 Mirror 反射获取属性
        let mirror = Mirror(reflecting: mediaURL)
        
        for child in mirror.children {
            if let label = child.label {
                // 寻找可能的 URL 相关属性
                if label == "absoluteString" || label == "url" || label == "string" || label == "sourceUrl" {
                    if let value = child.value as? String {
                        return URL(string: value)
                    }
                }
            }
        }
        
        // 如果反射失败，尝试描述
        let description = String(describing: mediaURL)
        if description.hasPrefix("MediaURL(") && description.hasSuffix(")") {
            let urlString = String(description.dropFirst("MediaURL(".count).dropLast())
            return URL(string: urlString)
        }
        
        return URL(string: description)
    }

    // MARK: - Bridged Methods

    @objc(setupPlayer:resolver:rejecter:)
    public func setupPlayer(config: [String: Any], resolve: @escaping RCTPromiseResolveBlock, reject: @escaping RCTPromiseRejectBlock) {
        if hasInitialized {
            reject("player_already_initialized", "The player has already been initialized via setupPlayer.", nil)
            return
        }

        playerQueue.async { [weak self] in
            guard let self = self else {
                DispatchQueue.main.async {
                    reject("player_error", "Player is not available", nil)
                }
                return
            }
            
            if let bufferDuration = config["minBuffer"] as? TimeInterval {
                self.player.bufferDuration = bufferDuration
            }

            if let autoHandleInterruptions = config["autoHandleInterruptions"] as? Bool {
                self.shouldResumePlaybackAfterInterruptionEnds = autoHandleInterruptions
            }

            if let waitForBuffer = config["waitForBuffer"] as? Bool {
                self.player.automaticallyWaitsToMinimizeStalling = waitForBuffer
            }

            self.player.automaticallyUpdateNowPlayingInfo = config["autoUpdateMetadata"] as? Bool ?? true

            if let sessionCategoryStr = config["iosCategory"] as? String,
               let mappedCategory = SessionCategory(rawValue: sessionCategoryStr) {
                self.sessionCategory = mappedCategory.mapConfigToAVAudioSessionCategory()
            }

            if let sessionCategoryModeStr = config["iosCategoryMode"] as? String,
               let mappedCategoryMode = SessionCategoryMode(rawValue: sessionCategoryModeStr) {
                self.sessionCategoryMode = mappedCategoryMode.mapConfigToAVAudioSessionCategoryMode()
            }

            if let sessionCategoryPolicyStr = config["iosCategoryPolicy"] as? String,
               let mappedCategoryPolicy = SessionCategoryPolicy(rawValue: sessionCategoryPolicyStr) {
                self.sessionCategoryPolicy = mappedCategoryPolicy.mapConfigToAVAudioSessionCategoryPolicy()
            }

            let sessionCategoryOptsStr = config["iosCategoryOptions"] as? [String]
            let mappedCategoryOpts = sessionCategoryOptsStr?.compactMap { SessionCategoryOptions(rawValue: $0)?.mapConfigToAVAudioSessionCategoryOptions() } ?? []
            self.sessionCategoryOptions = AVAudioSession.CategoryOptions(mappedCategoryOpts)

            self.configureAudioSession()

            // 配置远程命令
            self.configureRemoteCommands()

            DispatchQueue.main.async {
                self.hasInitialized = true
                resolve(NSNull())
            }
        }
    }
    
    private func configureRemoteCommands() {
        let controller = player.remoteCommandController
        
        controller.handleChangePlaybackPositionCommand = { [weak self] event in
            if let event = event as? MPChangePlaybackPositionCommandEvent {
                self?.emit(event: EventType.RemoteSeek, body: ["position": event.positionTime])
                return MPRemoteCommandHandlerStatus.success
            }
            return MPRemoteCommandHandlerStatus.commandFailed
        }

        controller.handleNextTrackCommand = { [weak self] _ in
            self?.emit(event: EventType.RemoteNext)
            return MPRemoteCommandHandlerStatus.success
        }

        controller.handlePauseCommand = { [weak self] _ in
            self?.emit(event: EventType.RemotePause)
            return MPRemoteCommandHandlerStatus.success
        }

        controller.handlePlayCommand = { [weak self] _ in
            self?.emit(event: EventType.RemotePlay)
            return MPRemoteCommandHandlerStatus.success
        }

        controller.handlePreviousTrackCommand = { [weak self] _ in
            self?.emit(event: EventType.RemotePrevious)
            return MPRemoteCommandHandlerStatus.success
        }

        controller.handleSkipBackwardCommand = { [weak self] event in
            if let command = event.command as? MPSkipIntervalCommand,
               let interval = command.preferredIntervals.first {
                self?.emit(event: EventType.RemoteJumpBackward, body: ["interval": interval])
                return MPRemoteCommandHandlerStatus.success
            }
            return MPRemoteCommandHandlerStatus.commandFailed
        }

        controller.handleSkipForwardCommand = { [weak self] event in
            if let command = event.command as? MPSkipIntervalCommand,
               let interval = command.preferredIntervals.first {
                self?.emit(event: EventType.RemoteJumpForward, body: ["interval": interval])
                return MPRemoteCommandHandlerStatus.success
            }
            return MPRemoteCommandHandlerStatus.commandFailed
        }

        controller.handleStopCommand = { [weak self] _ in
            self?.emit(event: EventType.RemoteStop)
            return MPRemoteCommandHandlerStatus.success
        }

        controller.handleTogglePlayPauseCommand = { [weak self] _ in
            self?.playerQueue.async {
                let isPaused = self?.player.playerState == .paused
                self?.emit(event: isPaused ? EventType.RemotePlay : EventType.RemotePause)
            }
            return MPRemoteCommandHandlerStatus.success
        }

        controller.handleLikeCommand = { [weak self] _ in
            self?.emit(event: EventType.RemoteLike)
            return MPRemoteCommandHandlerStatus.success
        }

        controller.handleDislikeCommand = { [weak self] _ in
            self?.emit(event: EventType.RemoteDislike)
            return MPRemoteCommandHandlerStatus.success
        }

        controller.handleBookmarkCommand = { [weak self] _ in
            self?.emit(event: EventType.RemoteBookmark)
            return MPRemoteCommandHandlerStatus.success
        }
    }

    @objc(isServiceRunning:rejecter:)
    public func isServiceRunning(resolve: RCTPromiseResolveBlock, reject: RCTPromiseRejectBlock) {
        resolve(hasInitialized)
    }

    @objc(updateOptions:resolver:rejecter:)
    public func update(options: [String: Any], resolve: @escaping RCTPromiseResolveBlock, reject: @escaping RCTPromiseRejectBlock) {
        if (rejectWhenNotInitialized(reject: reject)) { return }

        playerQueue.async { [weak self] in
            guard let self = self else {
                DispatchQueue.main.async {
                    reject("player_error", "Player is not available", nil)
                }
                return
            }
            
            var capabilitiesStr = options["capabilities"] as? [String] ?? []
            if (capabilitiesStr.contains("play") && capabilitiesStr.contains("pause")) {
                capabilitiesStr.append("togglePlayPause");
            }

            self.forwardJumpInterval = options["forwardJumpInterval"] as? NSNumber ?? self.forwardJumpInterval
            self.backwardJumpInterval = options["backwardJumpInterval"] as? NSNumber ?? self.backwardJumpInterval

            self.player.remoteCommands = capabilitiesStr
                .compactMap { Capability(rawValue: $0) }
                .map { capability in
                    capability.mapToPlayerCommand(
                        forwardJumpInterval: self.forwardJumpInterval,
                        backwardJumpInterval: self.backwardJumpInterval,
                        likeOptions: options["likeOptions"] as? [String: Any],
                        dislikeOptions: options["dislikeOptions"] as? [String: Any],
                        bookmarkOptions: options["bookmarkOptions"] as? [String: Any]
                    )
                }

            self.configureProgressUpdateEvent(
                interval: ((options["progressUpdateEventInterval"] as? NSNumber) ?? 0).doubleValue
            )

            DispatchQueue.main.async {
                resolve(NSNull())
            }
        }
    }

    private func configureProgressUpdateEvent(interval: Double) {
        playerQueue.async { [weak self] in
            guard let self = self else { return }
            
            self.shouldEmitProgressEvent = interval > 0
            self.player.timeEventFrequency = self.shouldEmitProgressEvent
                ? .custom(time: CMTime(seconds: interval, preferredTimescale: 1000))
                : .everySecond
        }
    }

    @objc(add:before:resolver:rejecter:)
    public func add(
        trackDicts: [[String: Any]],
        before trackIndex: NSNumber,
        resolve: @escaping RCTPromiseResolveBlock,
        reject: @escaping RCTPromiseRejectBlock
    ) {
        if (rejectWhenNotInitialized(reject: reject)) { return }
        
        let requestKey = "add-\(Date().timeIntervalSince1970)"
        guard beginRequest(requestKey) else {
            reject("request_in_progress", "Another add operation is in progress", nil)
            return
        }
        
        playerQueue.async { [weak self] in
            guard let self = self else {
                DispatchQueue.main.async {
                    reject("player_error", "Player is not available", nil)
                }
                self?.endRequest(requestKey)
                return
            }
            
            let index = trackIndex.intValue == -1 ? self.player.items.count : trackIndex.intValue
            
            // 修复：直接在 playerQueue 中检查，不使用 playerQueue.sync
            let itemCount = self.player.items.count
            let maxIndex = itemCount
            if index < 0 || index > maxIndex {
                self.endRequest(requestKey)
                DispatchQueue.main.async {
                    reject("index_out_of_bounds", "The track index is out of bounds", nil)
                }
                return
            }

            var tracks = [Track]()
            for trackDict in trackDicts {
                guard let track = Track(dictionary: trackDict) else {
                    self.endRequest(requestKey)
                    DispatchQueue.main.async {
                        reject("invalid_track_object", "Track is missing a required key", nil)
                    }
                    return
                }

                tracks.append(track)
            }

            do {
                try self.player.add(items: tracks, at: index)
                self.endRequest(requestKey)
                DispatchQueue.main.async {
                    resolve(index)
                }
            } catch {
                self.endRequest(requestKey)
                DispatchQueue.main.async {
                    reject("add_tracks_error", "Failed to add tracks: \(error.localizedDescription)", error)
                }
            }
        }
    }
    
    // 修复：检查音频资源是否有音频轨道（兼容 MP4 音频）
    private func checkAudioAsset(_ url: URL, completion: @escaping (Bool, Error?) -> Void) {
        let asset = AVURLAsset(url: url)
        
        // 如果是 MP4 格式，检查是否有音频轨道
        if url.pathExtension.lowercased() == "mp4" {
            asset.loadValuesAsynchronously(forKeys: ["tracks"]) {
                var error: NSError?
                let status = asset.statusOfValue(forKey: "tracks", error: &error)
                
                if status == .loaded {
                    let hasAudioTrack = asset.tracks(withMediaType: .audio).count > 0
                    completion(hasAudioTrack, error)
                } else if status == .failed {
                    // 加载失败，可能是无效的 MP4 文件
                    completion(false, error ?? NSError(domain: "RNTrackPlayer", code: -1, userInfo: [NSLocalizedDescriptionKey: "Failed to load tracks from MP4 file"]))
                } else {
                    // 其他状态，假设可以播放
                    completion(true, nil)
                }
            }
        } else {
            // 对于非 MP4 格式，假设可以播放
            completion(true, nil)
        }
    }

    @objc(load:resolver:rejecter:)
    public func load(
        trackDict: [String: Any],
        resolve: @escaping RCTPromiseResolveBlock,
        reject: @escaping RCTPromiseRejectBlock
    ) {
        if (rejectWhenNotInitialized(reject: reject)) { return }

        guard let track = Track(dictionary: trackDict) else {
            reject("invalid_track_object", "Track is missing a required key", nil)
            return
        }
        
        let requestKey = "load-\(Date().timeIntervalSince1970)"
        guard beginRequest(requestKey) else {
            reject("request_in_progress", "Another load operation is in progress", nil)
            return
        }

        playerQueue.async { [weak self] in
            guard let self = self else {
                DispatchQueue.main.async {
                    reject("player_error", "Player is not available", nil)
                }
                self?.endRequest(requestKey)
                return
            }
            
            // 修复：MediaURL 是非可选类型，直接使用
            let mediaURL = track.url
            
            // 尝试从 MediaURL 获取 URL
            if let url = self.getURLFromMediaURL(mediaURL) {
                self.checkAudioAsset(url) { canPlay, error in
                    self.playerQueue.async {
                        if canPlay {
                            self.player.load(item: track)
                            let currentIndex = self.player.currentIndex
                            self.endRequest(requestKey)
                            
                            DispatchQueue.main.async {
                                resolve(currentIndex)
                            }
                        } else {
                            self.endRequest(requestKey)
                            
                            let errorMessage = error?.localizedDescription ?? "Audio resource cannot be played"
                            let errorCode = "ios_audio_track_unplayable"
                            
                            // 标记播放器处于错误状态
                            self.isPlayerInErrorState = true
                            
                            DispatchQueue.main.async {
                                self.emit(event: EventType.PlaybackError, body: [
                                    "error": errorMessage,
                                    "code": errorCode
                                ])
                                reject("audio_unplayable", errorMessage, error)
                            }
                        }
                    }
                }
            } else {
                // 无法从 MediaURL 获取 URL，记录日志但继续加载
                print("Warning: Could not extract URL from MediaURL: \(mediaURL)")
                
                self.player.load(item: track)
                let currentIndex = self.player.currentIndex
                self.endRequest(requestKey)
                
                DispatchQueue.main.async {
                    resolve(currentIndex)
                }
            }
        }
    }

    @objc(remove:resolver:rejecter:)
    public func remove(tracks indexes: [Int], resolve: @escaping RCTPromiseResolveBlock, reject: @escaping RCTPromiseRejectBlock) {
        if (rejectWhenNotInitialized(reject: reject)) { return }
        
        let requestKey = "remove-\(Date().timeIntervalSince1970)"
        guard beginRequest(requestKey) else {
            reject("request_in_progress", "Another remove operation is in progress", nil)
            return
        }

        playerQueue.async { [weak self] in
            guard let self = self else {
                DispatchQueue.main.async {
                    reject("player_error", "Player is not available", nil)
                }
                self?.endRequest(requestKey)
                return
            }
            
            // 修复：直接在 playerQueue 中检查索引范围
            for index in indexes {
                if index < 0 || index >= self.player.items.count {
                    self.endRequest(requestKey)
                    DispatchQueue.main.async {
                        reject("index_out_of_bounds", "One or more of the indexes were out of bounds.", nil)
                    }
                    return
                }
            }

            do {
                for index in indexes.sorted().reversed() {
                    try self.player.removeItem(at: index)
                    // 清除播放位置记录
                    self.currentPlaybackPosition.removeValue(forKey: index)
                }
                self.endRequest(requestKey)
                
                DispatchQueue.main.async {
                    resolve(NSNull())
                }
            } catch {
                self.endRequest(requestKey)
                DispatchQueue.main.async {
                    reject("remove_tracks_error", "Failed to remove tracks: \(error.localizedDescription)", error)
                }
            }
        }
    }

    @objc(move:toIndex:resolver:rejecter:)
    public func move(
        fromIndex: NSNumber,
        toIndex: NSNumber,
        resolve: @escaping RCTPromiseResolveBlock,
        reject: @escaping RCTPromiseRejectBlock
    ) {
        if (rejectWhenNotInitialized(reject: reject)) { return }
        
        let requestKey = "move-\(Date().timeIntervalSince1970)"
        guard beginRequest(requestKey) else {
            reject("request_in_progress", "Another move operation is in progress", nil)
            return
        }

        playerQueue.async { [weak self] in
            guard let self = self else {
                DispatchQueue.main.async {
                    reject("player_error", "Player is not available", nil)
                }
                self?.endRequest(requestKey)
                return
            }
            
            let fromIdx = fromIndex.intValue
            let toIdx = toIndex.intValue
            
            // 修复：直接在 playerQueue 中检查索引范围
            if fromIdx < 0 || fromIdx >= self.player.items.count {
                self.endRequest(requestKey)
                DispatchQueue.main.async {
                    reject("index_out_of_bounds", "The fromIndex is out of bounds", nil)
                }
                return
            }
            
            if toIdx < 0 || toIdx > Int.max {
                self.endRequest(requestKey)
                DispatchQueue.main.async {
                    reject("index_out_of_bounds", "The toIndex is out of bounds", nil)
                }
                return
            }
            
            do {
                try self.player.moveItem(fromIndex: fromIdx, toIndex: toIdx)
                
                // 更新播放位置记录
                if let position = self.currentPlaybackPosition[fromIdx] {
                    self.currentPlaybackPosition.removeValue(forKey: fromIdx)
                    self.currentPlaybackPosition[toIdx] = position
                }
                
                self.endRequest(requestKey)
                
                DispatchQueue.main.async {
                    resolve(NSNull())
                }
            } catch {
                self.endRequest(requestKey)
                DispatchQueue.main.async {
                    reject("move_track_error", "Failed to move track: \(error.localizedDescription)", error)
                }
            }
        }
    }

    @objc(removeUpcomingTracks:rejecter:)
    public func removeUpcomingTracks(resolve: @escaping RCTPromiseResolveBlock, reject: @escaping RCTPromiseRejectBlock) {
        if (rejectWhenNotInitialized(reject: reject)) { return }

        playerQueue.async { [weak self] in
            self?.player.removeUpcomingItems()
            
            DispatchQueue.main.async {
                resolve(NSNull())
            }
        }
    }

    @objc(skip:initialTime:resolver:rejecter:)
    public func skip(
        to trackIndex: NSNumber,
        initialTime: Double,
        resolve: @escaping RCTPromiseResolveBlock,
        reject: @escaping RCTPromiseRejectBlock
    ) {
        let index = trackIndex.intValue
        if (rejectWhenNotInitialized(reject: reject)) { return }
        
        // 使用智能切换方法
        performSmartSwitch(to: index, initialTime: initialTime, isNext: false, resolve: resolve, reject: reject)
    }

    @objc(skipToNext:resolver:rejecter:)
    public func skipToNext(
        initialTime: Double,
        resolve: @escaping RCTPromiseResolveBlock,
        reject: @escaping RCTPromiseRejectBlock
    ) {
        if (rejectWhenNotInitialized(reject: reject)) { return }
        
        let requestKey = "skipNext-\(Date().timeIntervalSince1970)"
        guard beginRequest(requestKey) else {
            reject("request_in_progress", "Another skip operation is in progress", nil)
            return
        }

        playerQueue.async { [weak self] in
            guard let self = self else {
                DispatchQueue.main.async {
                    reject("player_error", "Player is not available", nil)
                }
                self?.endRequest(requestKey)
                return
            }
            
            // 检查是否有下一首
            let currentIndex = self.player.currentIndex
            let nextIndex = currentIndex + 1
            
            if nextIndex >= 0 && nextIndex < self.player.items.count {
                self.endRequest(requestKey)
                self.wasPlayingBeforeSwitch = self.player.playWhenReady
                // 关键修复：下一首应该从0开始，除非指定了initialTime
                let actualInitialTime = initialTime >= 0 ? initialTime : 0
                self.performSmartSwitch(to: nextIndex, initialTime: actualInitialTime, isNext: true, resolve: resolve, reject: reject)
            } else {
                self.endRequest(requestKey)
                DispatchQueue.main.async {
                    reject("no_next_track", "No next track available", nil)
                }
            }
        }
    }

    @objc(skipToPrevious:resolver:rejecter:)
    public func skipToPrevious(
        initialTime: Double,
        resolve: @escaping RCTPromiseResolveBlock,
        reject: @escaping RCTPromiseRejectBlock
    ) {
        if (rejectWhenNotInitialized(reject: reject)) { return }
        
        let requestKey = "skipPrev-\(Date().timeIntervalSince1970)"
        guard beginRequest(requestKey) else {
            reject("request_in_progress", "Another skip operation is in progress", nil)
            return
        }

        playerQueue.async { [weak self] in
            guard let self = self else {
                DispatchQueue.main.async {
                    reject("player_error", "Player is not available", nil)
                }
                self?.endRequest(requestKey)
                return
            }
            
            // 检查是否有上一首
            let currentIndex = self.player.currentIndex
            let previousIndex = currentIndex - 1
            
            if previousIndex >= 0 && previousIndex < self.player.items.count {
                self.endRequest(requestKey)
                self.wasPlayingBeforeSwitch = self.player.playWhenReady
                // 关键修复：上一首应该从0开始，除非指定了initialTime
                let actualInitialTime = initialTime >= 0 ? initialTime : 0
                self.performSmartSwitch(to: previousIndex, initialTime: actualInitialTime, isNext: true, resolve: resolve, reject: reject)
            } else {
                self.endRequest(requestKey)
                DispatchQueue.main.async {
                    reject("no_previous_track", "No previous track available", nil)
                }
            }
        }
    }

    @objc(reset:rejecter:)
    public func reset(resolve: @escaping RCTPromiseResolveBlock, reject: @escaping RCTPromiseRejectBlock) {
        if (rejectWhenNotInitialized(reject: reject)) { return }
        
        let requestKey = "reset-\(Date().timeIntervalSince1970)"
        guard beginRequest(requestKey) else {
            reject("request_in_progress", "Another reset operation is in progress", nil)
            return
        }

        playerQueue.async { [weak self] in
            guard let self = self else {
                DispatchQueue.main.async {
                    reject("player_error", "Player is not available", nil)
                }
                self?.endRequest(requestKey)
                return
            }
            
            self.player.stop()
            self.player.clear()
            
            // 修复：停用音频会话
            self.deactivateAudioSession()
            
            // 修复：重置初始化状态
            self.hasInitialized = false
            
            // 清理请求映射
            self.currentRequestMap.removeAll()
            
            // 重置所有状态
            self.resetPlayerErrorState()
            
            // 清除播放位置记录
            self.currentPlaybackPosition.removeAll()
            self.lastValidPosition = 0
            
            self.endRequest(requestKey)
            
            DispatchQueue.main.async {
                resolve(NSNull())
            }
        }
    }

    @objc(play:rejecter:)
    public func play(resolve: @escaping RCTPromiseResolveBlock, reject: @escaping RCTPromiseRejectBlock) {
        if (rejectWhenNotInitialized(reject: reject)) { return }
        
        let requestKey = "play-\(Date().timeIntervalSince1970)"
        guard beginRequest(requestKey) else {
            reject("request_in_progress", "Another play operation is in progress", nil)
            return
        }

        playerQueue.async { [weak self] in
            guard let self = self else {
                DispatchQueue.main.async {
                    reject("player_error", "Player is not available", nil)
                }
                self?.endRequest(requestKey)
                return
            }
            
            // 检查播放器是否处于错误状态
            if self.isPlayerInErrorState {
                // 尝试重置错误状态
                self.resetPlayerErrorState()
            }
            
            do {
                // 关键修复：在播放前确保状态正确
                if self.player.playerState == .failed {
                    try self.player.reload(startFromCurrentTime: true)
                }
                
                // 清除错误状态
                self.isPlayerInErrorState = false
                
                try self.player.play()
                self.endRequest(requestKey)
                
                DispatchQueue.main.async {
                    resolve(NSNull())
                }
            } catch {
                self.endRequest(requestKey)
                
                let errorMessage = error.localizedDescription
                
                // 重新获取当前索引
                let currentIndex = self.player.currentIndex
                
                DispatchQueue.main.async {
                    self.emit(event: EventType.PlaybackError, body: [
                        "error": errorMessage,
                        "code": "play_failed",
                        "trackIndex": currentIndex
                    ])
                    reject("play_error", errorMessage, error)
                }
            }
        }
    }

    @objc(pause:rejecter:)
    public func pause(resolve: @escaping RCTPromiseResolveBlock, reject: @escaping RCTPromiseRejectBlock) {
        if (rejectWhenNotInitialized(reject: reject)) { return }
        
        playerQueue.async { [weak self] in
            self?.player.pause()
            
            DispatchQueue.main.async {
                resolve(NSNull())
            }
        }
    }

    @objc(setPlayWhenReady:resolver:rejecter:)
    public func setPlayWhenReady(playWhenReady: Bool, resolve: @escaping RCTPromiseResolveBlock, reject: @escaping RCTPromiseRejectBlock) {
        if (rejectWhenNotInitialized(reject: reject)) { return }
        
        playerQueue.async { [weak self] in
            self?.player.playWhenReady = playWhenReady
            self?.configureAudioSession()
            
            DispatchQueue.main.async {
                resolve(NSNull())
            }
        }
    }

    @objc(getPlayWhenReady:rejecter:)
    public func getPlayWhenReady(resolve: @escaping RCTPromiseResolveBlock, reject: @escaping RCTPromiseRejectBlock) {
        if (rejectWhenNotInitialized(reject: reject)) { return }
        
        playerQueue.async { [weak self] in
            let playWhenReady = self?.player.playWhenReady ?? false
            
            DispatchQueue.main.async {
                resolve(playWhenReady)
            }
        }
    }

    @objc(stop:rejecter:)
    public func stop(resolve: @escaping RCTPromiseResolveBlock, reject: @escaping RCTPromiseRejectBlock) {
        if (rejectWhenNotInitialized(reject: reject)) { return }
        
        playerQueue.async { [weak self] in
            self?.player.stop()
            
            DispatchQueue.main.async {
                resolve(NSNull())
            }
        }
    }

    @objc(seekTo:resolver:rejecter:)
    public func seekTo(time: Double, resolve: @escaping RCTPromiseResolveBlock, reject: @escaping RCTPromiseRejectBlock) {
        if (rejectWhenNotInitialized(reject: reject)) { return }
        
        playerQueue.async { [weak self] in
            self?.isSeeking = true
            self?.player.seek(to: time)
            self?.isSeeking = false
            
            // 记录当前位置
            let currentIndex = self?.player.currentIndex ?? -1
            if currentIndex >= 0 {
                self?.currentPlaybackPosition[currentIndex] = time
                self?.lastValidPosition = time
            }
            
            DispatchQueue.main.async {
                resolve(NSNull())
            }
        }
    }

    @objc(seekBy:resolver:rejecter:)
    public func seekBy(offset: Double, resolve: @escaping RCTPromiseResolveBlock, reject: @escaping RCTPromiseRejectBlock) {
        if (rejectWhenNotInitialized(reject: reject)) { return }
        
        playerQueue.async { [weak self] in
            self?.isSeeking = true
            self?.player.seek(by: offset)
            self?.isSeeking = false
            
            // 更新当前位置
            let currentIndex = self?.player.currentIndex ?? -1
            let currentTime = self?.player.currentTime ?? 0
            if currentIndex >= 0 {
                self?.currentPlaybackPosition[currentIndex] = currentTime
                self?.lastValidPosition = currentTime
            }
            
            DispatchQueue.main.async {
                resolve(NSNull())
            }
        }
    }

    @objc(retry:rejecter:)
    public func retry(resolve: @escaping RCTPromiseResolveBlock, reject: @escaping RCTPromiseRejectBlock) {
        if (rejectWhenNotInitialized(reject: reject)) { return }
        
        playerQueue.async { [weak self] in
            self?.player.reload(startFromCurrentTime: true)
            
            // 重置错误状态和重试状态
            self?.resetPlayerErrorState()
            
            DispatchQueue.main.async {
                resolve(NSNull())
            }
        }
    }

    @objc(setRepeatMode:resolver:rejecter:)
    public func setRepeatMode(repeatMode: NSNumber, resolve: @escaping RCTPromiseResolveBlock, reject: @escaping RCTPromiseRejectBlock) {
        if (rejectWhenNotInitialized(reject: reject)) { return }
        
        playerQueue.async { [weak self] in
            self?.player.repeatMode = SwiftAudioEx.RepeatMode(rawValue: repeatMode.intValue) ?? .off
            
            DispatchQueue.main.async {
                resolve(NSNull())
            }
        }
    }

    @objc(getRepeatMode:rejecter:)
    public func getRepeatMode(resolve: @escaping RCTPromiseResolveBlock, reject: @escaping RCTPromiseRejectBlock) {
        if (rejectWhenNotInitialized(reject: reject)) { return }
        
        playerQueue.async { [weak self] in
            let repeatMode = self?.player.repeatMode.rawValue ?? 0
            
            DispatchQueue.main.async {
                resolve(repeatMode)
            }
        }
    }

    @objc(setVolume:resolver:rejecter:)
    public func setVolume(level: Float, resolve: @escaping RCTPromiseResolveBlock, reject: @escaping RCTPromiseRejectBlock) {
        if (rejectWhenNotInitialized(reject: reject)) { return }
        
        playerQueue.async { [weak self] in
            self?.player.volume = level
            
            DispatchQueue.main.async {
                resolve(NSNull())
            }
        }
    }

    @objc(getVolume:rejecter:)
    public func getVolume(resolve: @escaping RCTPromiseResolveBlock, reject: @escaping RCTPromiseRejectBlock) {
        if (rejectWhenNotInitialized(reject: reject)) { return }
        
        playerQueue.async { [weak self] in
            let volume = self?.player.volume ?? 0
            
            DispatchQueue.main.async {
                resolve(volume)
            }
        }
    }

    @objc(setRate:resolver:rejecter:)
    public func setRate(rate: Float, resolve: @escaping RCTPromiseResolveBlock, reject: @escaping RCTPromiseRejectBlock) {
        if (rejectWhenNotInitialized(reject: reject)) { return }
        
        playerQueue.async { [weak self] in
            self?.player.rate = rate
            
            DispatchQueue.main.async {
                resolve(NSNull())
            }
        }
    }

    @objc(getRate:rejecter:)
    public func getRate(resolve: @escaping RCTPromiseResolveBlock, reject: @escaping RCTPromiseRejectBlock) {
        if (rejectWhenNotInitialized(reject: reject)) { return }
        
        playerQueue.async { [weak self] in
            let rate = self?.player.rate ?? 1.0
            
            DispatchQueue.main.async {
                resolve(rate)
            }
        }
    }

    @objc(getTrack:resolver:rejecter:)
    public func getTrack(index: NSNumber, resolve: @escaping RCTPromiseResolveBlock, reject: @escaping RCTPromiseRejectBlock) {
        if (rejectWhenNotInitialized(reject: reject)) { return }
        
        playerQueue.async { [weak self] in
            let track = index.intValue >= 0 && index.intValue < (self?.player.items.count ?? 0)
                ? (self?.player.items[index.intValue] as? Track)?.toObject()
                : nil
            
            DispatchQueue.main.async {
                resolve(track ?? NSNull())
            }
        }
    }

    @objc(getQueue:rejecter:)
    public func getQueue(resolve: @escaping RCTPromiseResolveBlock, reject: @escaping RCTPromiseRejectBlock) {
        if (rejectWhenNotInitialized(reject: reject)) { return }
        
        playerQueue.async { [weak self] in
            let serializedQueue = self?.player.items.map { ($0 as? Track)?.toObject() as Any ?? NSNull() } ?? []
            
            DispatchQueue.main.async {
                resolve(serializedQueue)
            }
        }
    }

    @objc(setQueue:resolver:rejecter:)
    public func setQueue(
        trackDicts: [[String: Any]],
        resolve: @escaping RCTPromiseResolveBlock,
        reject: @escaping RCTPromiseRejectBlock
    ) {
        if (rejectWhenNotInitialized(reject: reject)) { return }
        
        let requestKey = "setQueue-\(Date().timeIntervalSince1970)"
        guard beginRequest(requestKey) else {
            reject("request_in_progress", "Another setQueue operation is in progress", nil)
            return
        }

        playerQueue.async { [weak self] in
            guard let self = self else {
                DispatchQueue.main.async {
                    reject("player_error", "Player is not available", nil)
                }
                self?.endRequest(requestKey)
                return
            }
            
            var tracks = [Track]()
            for trackDict in trackDicts {
                guard let track = Track(dictionary: trackDict) else {
                    self.endRequest(requestKey)
                    DispatchQueue.main.async {
                        reject("invalid_track_object", "Track is missing a required key", nil)
                    }
                    return
                }

                tracks.append(track)
            }
            
            do {
                self.player.clear()
                try self.player.add(items: tracks)
                let index = self.player.items.count - 1
                self.endRequest(requestKey)
                
                DispatchQueue.main.async {
                    resolve(index)
                }
            } catch {
                self.endRequest(requestKey)
                DispatchQueue.main.async {
                    reject("set_queue_error", "Failed to set queue: \(error.localizedDescription)", error)
                }
            }
        }
    }

    @objc(getActiveTrack:rejecter:)
    public func getActiveTrack(resolve: @escaping RCTPromiseResolveBlock, reject: @escaping RCTPromiseRejectBlock) {
        if (rejectWhenNotInitialized(reject: reject)) { return }
        
        playerQueue.async { [weak self] in
            let index = self?.player.currentIndex ?? -1
            let track = index >= 0 && index < (self?.player.items.count ?? 0)
                ? (self?.player.items[index] as? Track)?.toObject()
                : nil
            
            DispatchQueue.main.async {
                resolve(track ?? NSNull())
            }
        }
    }

    @objc(getActiveTrackIndex:rejecter:)
    public func getActiveTrackIndex(resolve: @escaping RCTPromiseResolveBlock, reject: @escaping RCTPromiseRejectBlock) {
        if (rejectWhenNotInitialized(reject: reject)) { return }
        
        playerQueue.async { [weak self] in
            let index = self?.player.currentIndex ?? -1
            
            DispatchQueue.main.async {
                if index < 0 || index >= (self?.player.items.count ?? 0) {
                    resolve(NSNull())
                } else {
                    resolve(index)
                }
            }
        }
    }

    @objc(getDuration:rejecter:)
    public func getDuration(resolve: @escaping RCTPromiseResolveBlock, reject: RCTPromiseRejectBlock) {
        if (rejectWhenNotInitialized(reject: reject)) { return }
        
        playerQueue.async { [weak self] in
            let duration = self?.player.duration ?? 0
            
            DispatchQueue.main.async {
                resolve(duration)
            }
        }
    }

    @objc(getBufferedPosition:rejecter:)
    public func getBufferedPosition(resolve: @escaping RCTPromiseResolveBlock, reject: RCTPromiseRejectBlock) {
        if (rejectWhenNotInitialized(reject: reject)) { return }
        
        playerQueue.async { [weak self] in
            let bufferedPosition = self?.player.bufferedPosition ?? 0
            
            DispatchQueue.main.async {
                resolve(bufferedPosition)
            }
        }
    }

    @objc(getPosition:rejecter:)
    public func getPosition(resolve: @escaping RCTPromiseResolveBlock, reject: RCTPromiseRejectBlock) {
        if (rejectWhenNotInitialized(reject: reject)) { return }
        
        playerQueue.async { [weak self] in
            let currentTime = self?.player.currentTime ?? 0
            
            DispatchQueue.main.async {
                resolve(currentTime)
            }
        }
    }

    @objc(getProgress:rejecter:)
    public func getProgress(resolve: @escaping RCTPromiseResolveBlock, reject: RCTPromiseRejectBlock) {
        if (rejectWhenNotInitialized(reject: reject)) { return }
        
        playerQueue.async { [weak self] in
            let progress = [
                "position": self?.player.currentTime ?? 0,
                "duration": self?.player.duration ?? 0,
                "buffered": self?.player.bufferedPosition ?? 0
            ]
            
            DispatchQueue.main.async {
                resolve(progress)
            }
        }
    }

    @objc(getPlaybackState:rejecter:)
    public func getPlaybackState(resolve: @escaping RCTPromiseResolveBlock, reject: RCTPromiseRejectBlock) {
        if (rejectWhenNotInitialized(reject: reject)) { return }
        
        playerQueue.async { [weak self] in
            let stateBody = self?.getPlaybackStateBodyKeyValues(state: self?.player.playerState ?? .idle) ?? ["state": State.none.rawValue]
            
            DispatchQueue.main.async {
                resolve(stateBody)
            }
        }
    }

    @objc(updateMetadataForTrack:metadata:resolver:rejecter:)
    public func updateMetadata(for trackIndex: NSNumber, metadata: [String: Any], resolve: @escaping RCTPromiseResolveBlock, reject: @escaping RCTPromiseRejectBlock) {
        let index = trackIndex.intValue
        if (rejectWhenNotInitialized(reject: reject)) { return }
        
        let requestKey = "updateMetadata-\(Date().timeIntervalSince1970)"
        guard beginRequest(requestKey) else {
            reject("request_in_progress", "Another metadata update operation is in progress", nil)
            return
        }

        playerQueue.async { [weak self] in
            guard let self = self else {
                DispatchQueue.main.async {
                    reject("player_error", "Player is not available", nil)
                }
                self?.endRequest(requestKey)
                return
            }
            
            if index < 0 || index >= self.player.items.count {
                self.endRequest(requestKey)
                DispatchQueue.main.async {
                    reject("index_out_of_bounds", "The track index is out of bounds", nil)
                }
                return
            }
            
            guard let track = self.player.items[index] as? Track else {
                self.endRequest(requestKey)
                DispatchQueue.main.async {
                    reject("invalid_track", "Track at index \(index) is not a valid Track", nil)
                }
                return
            }
            
            track.updateMetadata(dictionary: metadata)

            if (self.player.currentIndex == index) {
                // QueuedAudioPlayer 已经继承自 AudioPlayer，直接使用
                Metadata.update(for: self.player, with: metadata)
            }
            
            self.endRequest(requestKey)
            
            DispatchQueue.main.async {
                resolve(NSNull())
            }
        }
    }

    @objc(clearNowPlayingMetadata:rejecter:)
    public func clearNowPlayingMetadata(resolve: @escaping RCTPromiseResolveBlock, reject: @escaping RCTPromiseRejectBlock) {
        if (rejectWhenNotInitialized(reject: reject)) { return }

        playerQueue.async { [weak self] in
            self?.player.nowPlayingInfoController.clear()
            
            DispatchQueue.main.async {
                resolve(NSNull())
            }
        }
    }

    @objc(updateNowPlayingMetadata:resolver:rejecter:)
    public func updateNowPlayingMetadata(metadata: [String: Any], resolve: @escaping RCTPromiseResolveBlock, reject: @escaping RCTPromiseRejectBlock) {
        if (rejectWhenNotInitialized(reject: reject)) { return }

        playerQueue.async { [weak self] in
            // QueuedAudioPlayer 已经继承自 AudioPlayer，直接使用
            if let player = self?.player {
                Metadata.update(for: player, with: metadata)
            }
            
            DispatchQueue.main.async {
                resolve(NSNull())
            }
        }
    }

    private func getPlaybackStateErrorKeyValues() -> Dictionary<String, Any> {
        switch player.playbackError {
            case .failedToLoadKeyValue: return [
                "message": "Failed to load resource",
                "code": "ios_failed_to_load_resource"
            ]
            case .invalidSourceUrl: return [
                "message": "The source url was invalid",
                "code": "ios_invalid_source_url"
            ]
            case .notConnectedToInternet: return [
                "message": "A network resource was requested, but an internet connection has not been established and can't be established automatically.",
                "code": "ios_not_connected_to_internet"
            ]
            case .playbackFailed: return [
                "message": "Playback of the track failed",
                "code": "ios_playback_failed"
            ]
            case .itemWasUnplayable: return [
                "message": "The track could not be played",
                "code": "ios_track_unplayable"
            ]
            default: return [
                "message": "A playback error occurred",
                "code": "ios_playback_error"
            ]
        }
    }

    private func getPlaybackStateBodyKeyValues(state: AudioPlayerState) -> Dictionary<String, Any> {
        var body: Dictionary<String, Any> = ["state": State.fromPlayerState(state: state).rawValue]
        if (state == AudioPlayerState.failed) {
            body["error"] = getPlaybackStateErrorKeyValues()
        }
        return body
    }

    // MARK: - QueuedAudioPlayer Event Handlers（修复：全部在 playerQueue 中处理）

    func handleAudioPlayerStateChange(state: AVPlayerWrapperState) {
        playerQueue.async { [weak self] in
            guard let self = self else { return }
            
            let body = self.getPlaybackStateBodyKeyValues(state: state)
            
            DispatchQueue.main.async {
                self.emit(event: EventType.PlaybackState, body: body)
            }
            
            if (state == .ended) {
                let endEventBody: [String: Any] = [
                    "track": self.player.currentIndex,
                    "position": self.player.currentTime,
                ]
                
                DispatchQueue.main.async {
                    self.emit(event: EventType.PlaybackQueueEnded, body: endEventBody)
                }
            }
        }
    }
    
    func handleAudioPlayerCommonMetadataReceived(metadata: [AVMetadataItem]) {
        let commonMetadata = MetadataAdapter.convertToCommonMetadata(metadata: metadata, skipRaw: true)
        
        DispatchQueue.main.async { [weak self] in
            self?.emit(event: EventType.MetadataCommonReceived, body: ["metadata": commonMetadata])
        }
    }
    
    func handleAudioPlayerChapterMetadataReceived(metadata: [AVTimedMetadataGroup]) {
        let metadataItems = MetadataAdapter.convertToGroupedMetadata(metadataGroups: metadata);
        
        DispatchQueue.main.async { [weak self] in
            self?.emit(event: EventType.MetadataChapterReceived, body: ["metadata": metadataItems])
        }
    }

    func handleAudioPlayerTimedMetadataReceived(metadata: [AVTimedMetadataGroup]) {
        let metadataItems = MetadataAdapter.convertToGroupedMetadata(metadataGroups: metadata);
        
        DispatchQueue.main.async { [weak self] in
            self?.emit(event: EventType.MetadataTimedReceived, body: ["metadata": metadataItems])
            
            let metadata = metadata.first?.items ?? []
            let metadataItem = MetadataAdapter.legacyConversion(metadata: metadata)
            self?.emit(event: EventType.PlaybackMetadataReceived, body: metadataItem)
        }
    }

    func handleAudioPlayerFailed(error: Error?) {
        playerQueue.async { [weak self] in
            guard let self = self else { return }
            
            print("Playback failed with error: \(String(describing: error))")
            
            let errorMessage = error?.localizedDescription ?? "Unknown playback error"
            
            // 检查是否正在切换曲目，如果是则不进行重试
            if self.isSwitchingTrack {
                print("正在切换曲目，跳过重试")
                return
            }
            
            // 检查是否已经在重试中
            if self.isRetrying {
                print("已经在重试中，跳过新的重试请求")
                return
            }
            
            // 检查是否正在seek
            if self.isSeeking {
                print("正在seek，跳过重试")
                return
            }
            
            // 检查播放器当前状态
            let playerState = self.player.playerState
            if playerState == .playing || playerState == .buffering {
                print("播放器已经在播放状态，跳过重试")
                return
            }
            
            // 检查当前是否有正在播放的曲目
            if self.player.currentIndex < 0 {
                print("没有正在播放的曲目，跳过重试")
                return
            }
            
            
            // 所有错误都重试3次，不区分错误类型
            print("播放失败，开始\(self.maxRetryCount)次重试机制")
            self.retryPlaybackWithDelay()
        }
    }

    func handleAudioPlayerCurrentItemChange(
        item: AudioItem?,
        index: Int?,
        lastItem: AudioItem?,
        lastIndex: Int?,
        lastPosition: Double?
    ) {
        playerQueue.async { [weak self] in
            guard let self = self else { return }
            
            // 当前项目切换时，重置所有相关状态
            if item != nil {
                // 重置错误状态
                self.isPlayerInErrorState = false
                // 重置重试状态
                self.resetRetryState()
                // 重置切换状态
                self.isSwitchingTrack = false
                self.pendingSwitchIndex = nil
                // 重置seek状态
                self.isSeeking = false
            }
            
            if let item = item {
                DispatchQueue.main.async {
                    UIApplication.shared.beginReceivingRemoteControlEvents();
                }
                if self.player.automaticallyUpdateNowPlayingInfo {
                    let isTrackLiveStream = (item as? Track)?.isLiveStream ?? false
                    self.player.nowPlayingInfoController.set(keyValue: NowPlayingInfoProperty.isLiveStream(isTrackLiveStream))
                }
            } else {
                DispatchQueue.main.async {
                    UIApplication.shared.endReceivingRemoteControlEvents();
                }
            }

            var a: Dictionary<String, Any> = ["lastPosition": lastPosition ?? 0]
            if let lastIndex = lastIndex {
                a["lastIndex"] = lastIndex
            }

            if let lastTrack = (lastItem as? Track)?.toObject() {
                a["lastTrack"] = lastTrack
            }

            if let index = index {
                a["index"] = index
            }

            if let track = (item as? Track)?.toObject() {
                a["track"] = track
            }
            
            DispatchQueue.main.async {
                self.emit(event: EventType.PlaybackActiveTrackChanged, body: a)
            }

            var b: Dictionary<String, Any> = ["position": lastPosition ?? 0]
            if let lastIndex = lastIndex {
                b["lastIndex"] = lastIndex
            }
            if let index = index {
                b["nextTrack"] = index
            }
            
            DispatchQueue.main.async {
                self.emit(event: EventType.PlaybackTrackChanged, body: b)
            }
        }
    }

    func handleAudioPlayerSecondElapse(seconds: Double) {
        playerQueue.async { [weak self] in
            guard let self = self else { return }
            
            let playerState = self.player.playerState
            
            // 关键修复：检查是否处于错误状态
            if self.isPlayerInErrorState && playerState == .playing {
                // 如果标记为错误状态但播放器正在播放，重置错误状态
                self.isPlayerInErrorState = false
            }
            
            // 关键修复：检查播放器是否处于失败状态
            
            if playerState == .failed || self.isPlayerInErrorState {
                // 播放器失败或处于错误状态，不发送进度更新
                print("播放器处于失败状态，跳过进度更新")
                return
            }
            
            // 新增：检查播放器是否准备好（只有 ready/playing/buffering 状态才更新进度）
//            let isPlayerReadyForProgress = playerState == .ready ||
//                                          playerState == .playing ||
//                                          playerState == .buffering
            
            if !self.shouldEmitProgressEvent ||
               self.player.currentItem == nil ||
                self.isPlayerInErrorState {
                print("跳过进度更新: playerState=\(playerState), hasItem=\(self.player.currentItem != nil)")
                return
            }
            
            let progressBody = [
                "position": self.player.currentTime,
                "duration": self.player.duration,
                "buffered": self.player.bufferedPosition,
                "track": self.player.currentIndex,
            ]
//            print("发送更新进度emit")
            DispatchQueue.main.async {
                self.emit(event: EventType.PlaybackProgressUpdated, body: progressBody)
            }
        }
    }

    func handlePlayWhenReadyChange(playWhenReady: Bool) {
        playerQueue.async { [weak self] in
            self?.configureAudioSession()
            
            let body = ["playWhenReady": playWhenReady]
            
            DispatchQueue.main.async {
                self?.emit(event: EventType.PlaybackPlayWhenReadyChanged, body: body)
            }
        }
    }
    
    // 新增：处理 AVPlayer 重新创建
    func handleAVPlayerRecreated() {
        playerQueue.async { [weak self] in
            print("AVPlayer was recreated, ensuring audio session is active")
            self?.configureAudioSession()
        }
    }
    
    // 新增：防止无限循环的安全检查
    private func checkRetrySafety() -> Bool {
        // 如果重试次数异常高，可能是无限循环
        if retryCount > maxRetryCount {
            print("⚠️ 安全警告：重试次数异常 (\(retryCount))，强制停止重试")
            resetRetryState()
            isPlayerInErrorState = true
            
            // 自动跳过当前曲目
            autoSkipToNextPlayableTrack()
            return false
        }
        
        // 检查是否在短时间内重复失败
        if retryCount > 0 && Date().timeIntervalSince(lastRetryStartTime) > 30 {
            print("⚠️ 安全警告：重试时间过长，强制停止")
            resetRetryState()
            return false
        }
        
        return true
    }
}

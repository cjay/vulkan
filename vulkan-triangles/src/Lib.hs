{-# LANGUAGE DataKinds           #-}
{-# LANGUAGE LambdaCase          #-}
{-# LANGUAGE NamedFieldPuns      #-}
{-# LANGUAGE RecordWildCards     #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE Strict              #-}
{-# LANGUAGE TemplateHaskell     #-}
{-# LANGUAGE TypeApplications    #-}
module Lib
  ( runVulkanProgram
  , WhichDemo (..)
  ) where

import           Control.Concurrent.MVar
import           Control.Monad                        (forM_, when)
import           Data.IORef
import           Data.Maybe                           (fromJust)
import           Graphics.Vulkan.Core_1_0
import           Graphics.Vulkan.Ext.VK_KHR_swapchain
import           Numeric.DataFrame
import           Numeric.Dimensions
import           System.Directory                     (doesFileExist)

import           Lib.GLFW
import           Lib.Program
import           Lib.Program.Foreign
import           Lib.Vulkan.Descriptor
import           Lib.Vulkan.Device
import           Lib.Vulkan.Drawing
import           Lib.Vulkan.Image
import           Lib.Vulkan.Pipeline
import           Lib.Vulkan.Presentation
import           Lib.Vulkan.Shader
import           Lib.Vulkan.Shader.TH
import           Lib.Vulkan.Sync
import           Lib.Vulkan.TransformationObject
import           Lib.Vulkan.Vertex
import           Lib.Vulkan.VertexBuffer


-- | Interleaved array of vertices containing at least 3 entries.
--
--   Obviously, in real world vertices come from a separate file and not known at compile time.
--   The shader pipeline requires at least 3 unique vertices (for a triangle)
--   to render something on a screen. Setting `XN 3` here is just a handy way
--   to statically ensure the program satisfies this requirement.
--   This way, not-enough-vertices error occures at the moment of DataFrame initialization
--   instead of silently failing to render something onto a screen.
--
--   Note: in this program, `n >= 3` requirement is also forced in `Lib/Vulkan/VertexBuffer.hs`,
--         where it is not strictly necessary but allows to avoid specifying DataFrame constraints
--         in function signatures (such as, e.g. `KnownDim n`).
rectVertices :: DataFrame Vertex '[XN 3]
rectVertices = fromJust $ fromList (D @3)
  [ -- rectangle
    --              coordinate                  color        texture coordinate
    scalar $ Vertex (vec3 (-0.5) (-0.5)   0.0 ) (vec3 1 0 0) (vec2 0 0)
  , scalar $ Vertex (vec3   0.4  (-0.5)   0.0 ) (vec3 0 1 0) (vec2 1 0)
  , scalar $ Vertex (vec3   0.4    0.4    0.0 ) (vec3 0 0 1) (vec2 1 1)
  , scalar $ Vertex (vec3 (-0.5)   0.4    0.0 ) (vec3 1 1 1) (vec2 0 1)

    -- rectangle
    --              coordinate                  color        texture coordinate
  , scalar $ Vertex (vec3 (-0.5) (-0.5) (-0.5)) (vec3 1 0 0) (vec2 0 0)
  , scalar $ Vertex (vec3   0.4  (-0.5) (-0.5)) (vec3 0 1 0) (vec2 1 0)
  , scalar $ Vertex (vec3   0.4    0.4  (-0.5)) (vec3 0 0 1) (vec2 1 1)
  , scalar $ Vertex (vec3 (-0.5)   0.4  (-0.5)) (vec3 1 1 1) (vec2 0 1)

    -- triangle
  -- , scalar $ Vertex (vec2   0.9 (-0.4)) (vec3 0.2 0.5 0)
  -- , scalar $ Vertex (vec2   0.5 (-0.4)) (vec3 0 1 1)
  -- , scalar $ Vertex (vec2   0.7 (-0.8)) (vec3 1 0 0.4)
  ]

rectIndices :: DataFrame Word32 '[XN 3]
rectIndices = fromJust $ fromList (D @3)
  [ -- rectangle
    0, 1, 2, 2, 3, 0
    -- rectangle
  , 4, 5, 6, 6, 7, 4
    -- triangle
  -- , 4, 5, 6
  ]

data WhichDemo = Squares | Chalet

runVulkanProgram :: WhichDemo -> IO ()
runVulkanProgram demo = runProgram checkStatus $ do
  windowSizeChanged <- liftIO $ newIORef False
  window <- initGLFWWindow 800 600 "vulkan-triangles-GLFW" windowSizeChanged

  vulkanInstance <- createGLFWVulkanInstance "vulkan-triangles-instance"

  vulkanSurface <- createSurface vulkanInstance window
  logInfo $ "Createad surface: " ++ show vulkanSurface

  glfwWaitEventsMeanwhile $ do
    (_, pdev) <- pickPhysicalDevice vulkanInstance (Just vulkanSurface)
    logInfo $ "Selected physical device: " ++ show pdev

    (dev, queues) <- createGraphicsDevice pdev vulkanSurface
    logInfo $ "Createad device: " ++ show dev
    logInfo $ "Createad queues: " ++ show queues

    shaderVert
      <- createVkShaderStageCI dev
            $(compileGLSL "shaders/triangle.vert")
            VK_SHADER_STAGE_VERTEX_BIT

    shaderFrag
      <- createVkShaderStageCI dev
            $(compileGLSL "shaders/triangle.frag")
            VK_SHADER_STAGE_FRAGMENT_BIT

    logInfo $ "Createad vertex shader module: " ++ show shaderVert
    logInfo $ "Createad fragment shader module: " ++ show shaderFrag

    curFrameRef <- liftIO $ newIORef 0
    rendFinS <- createFrameSemaphores dev
    imAvailS <- createFrameSemaphores dev
    inFlightF <- createFrameFences dev
    commandPool <- createCommandPool dev queues
    logInfo $ "Createad command pool: " ++ show commandPool

    -- we need this later, but don't want to realloc every swapchain recreation.
    imgIPtr <- mallocRes

    (vertices, indices) <- case demo of
      Squares -> return (rectVertices, rectIndices)
      Chalet -> do
        modelExist <- liftIO $ doesFileExist "models/chalet.obj"
        when (not modelExist) $
          throwVkMsg "Get models/chalet.obj and textures/chalet.jpg from the links in https://vulkan-tutorial.com/Loading_models"
        loadModel "models/chalet.obj"

    vertexBuffer <-
      createVertexBuffer pdev dev commandPool (graphicsQueue queues) vertices

    indexBuffer <-
      createIndexBuffer pdev dev commandPool (graphicsQueue queues) indices

    descriptorSetLayout <- createDescriptorSetLayout dev
    pipelineLayout <- createPipelineLayout dev descriptorSetLayout

    let texturePath = case demo of
          Squares -> "textures/texture.jpg"
          Chalet  -> "textures/chalet.jpg"
    texture <- createTextureImage pdev dev commandPool (graphicsQueue queues) texturePath
    textureView <- createTextureImageView dev texture
    textureSampler <- createTextureSampler dev
    descriptorTextureInfo <- textureImageInfo textureView textureSampler

    depthFormat <- findDepthFormat pdev

    -- handling lifetime of swapchain manually. createSwapChain does not deallocate via continuation.
    swapchainResource <- liftIO $ newEmptyMVar
    oldSwapchainResource <- liftIO $ newEmptyMVar

    oldSwapchainFence <- createFence dev True
    oldSwapchainFencePtr <- newArrayRes [oldSwapchainFence]

    let beforeSwapchainCreation :: Program r ()
        beforeSwapchainCreation = do
          -- wait as long as window has width=0 and height=0
          -- commented out because this only works in the main thread:
          -- glfwWaitMinimized window

          -- If a window size change did happen, it will be respected by (re-)creating
          -- the swapchain below, no matter if it was signalled via exception or
          -- the IORef, so reset the IORef now:
          liftIO $ atomicWriteIORef windowSizeChanged False

    -- creating first swapchain before loop
    beforeSwapchainCreation
    scsd <- querySwapchainSupport pdev vulkanSurface
    swapInfoRef <- createSwapchain dev scsd queues vulkanSurface swapchainResource oldSwapchainResource >>= liftIO . newIORef

    -- The code below re-runs when the swapchain was re-created and has a
    -- different number of images than before:
    _ <- flip finally (destroySwapchainIfNecessary dev swapchainResource)
      $ asyncRedo $ \redoDifferentLength -> do
      logInfo "New thread: Creating things that depend on the swapchain length.."
      swapInfo0 <- liftIO $ readIORef swapInfoRef
      let swapchainLen0 = length (swapImgs swapInfo0)

      (transObjMems, transObjBufs) <- unzip <$> createTransObjBuffers pdev dev swapchainLen0
      descriptorBufferInfos <- mapM transObjBufferInfo transObjBufs

      descriptorPool <- createDescriptorPool dev swapchainLen0
      descriptorSetLayouts <- newArrayRes $ replicate swapchainLen0 descriptorSetLayout
      descriptorSets <- createDescriptorSets dev descriptorPool swapchainLen0 descriptorSetLayouts

      forM_ (zip descriptorBufferInfos descriptorSets) $
        \(bufInfo, dSet) -> prepareDescriptorSet dev bufInfo descriptorTextureInfo dSet

      transObjMemories <- newArrayRes $ transObjMems

      -- The code below re-runs when the swapchain was re-created and has the
      -- same number of images as before, or continues from enclosing scope.
      asyncRedo $ \redoSameLength -> flip finally (destroySwapchainIfNecessary dev oldSwapchainResource) $ do
        logInfo "New thread: Creating things that depend on the swapchain, not only its length.."
        swapInfo <- liftIO $ readIORef swapInfoRef
        let swapchainLen = length (swapImgs swapInfo)
        imgViews <- mapM (\image -> createImageView dev image (swapImgFormat swapInfo) VK_IMAGE_ASPECT_COLOR_BIT) (swapImgs swapInfo)
        renderPass <- createRenderPass dev swapInfo depthFormat
        graphicsPipeline
          <- createGraphicsPipeline dev swapInfo
                                    vertIBD vertIADs
                                    [shaderVert, shaderFrag]
                                    renderPass
                                    pipelineLayout

        depthImgView <- createDepthImgView pdev dev commandPool (graphicsQueue queues) (swapExtent swapInfo)
        framebuffers
          <- createFramebuffers dev renderPass swapInfo imgViews depthImgView
        cmdBuffersPtr <- createCommandBuffers dev graphicsPipeline commandPool
                                          renderPass pipelineLayout swapInfo
                                          vertexBuffer
                                          (fromIntegral $ dimSize1 indices, indexBuffer)
                                          framebuffers
                                          descriptorSets

        let rdata = RenderData
              { device             = dev
              , swapchainInfo      = swapInfo
              , deviceQueues       = queues
              , imgIndexPtr        = imgIPtr
              , currentFrame       = curFrameRef
              , renderFinishedSems = rendFinS
              , imageAvailableSems = imAvailS
              , inFlightFences     = inFlightF
              , commandBuffers     = cmdBuffersPtr
              , memories           = transObjMemories
              , memoryMutator      = updateTransObj dev (swapExtent swapInfo)
              }

        logInfo $ "Createad image views: " ++ show imgViews
        logInfo $ "Createad renderpass: " ++ show renderPass
        logInfo $ "Createad pipeline: " ++ show graphicsPipeline
        logInfo $ "Createad framebuffers: " ++ show framebuffers
        cmdBuffers <- peekArray swapchainLen cmdBuffersPtr
        logInfo $ "Createad command buffers: " ++ show cmdBuffers

        -- part of dumb fps counter
        frameCount <- liftIO $ newIORef @Int 0
        currentSec <- liftIO $ newIORef @Int 0

        shouldExit <- glfwMainLoop window $ do
          return () -- do some app logic

          needRecreation <- drawFrame rdata `catchError` ( \err@(VulkanException ecode _) ->
            case ecode of
              Just VK_ERROR_OUT_OF_DATE_KHR -> do
                logInfo "Have got a VK_ERROR_OUT_OF_DATE_KHR error"
                return True
              _ -> throwError err
            )

          -- part of dumb fps counter
          seconds <- getTime
          liftIO $ do
            cur <- readIORef currentSec
            if floor seconds /= cur then do
              count <- readIORef frameCount
              when (cur /= 0) $ print count
              writeIORef currentSec (floor seconds)
              writeIORef frameCount 0
            else do
              modifyIORef frameCount $ \c -> c + 1

          sizeChanged <- liftIO $ readIORef windowSizeChanged
          when sizeChanged $ logInfo "Have got a windowSizeCallback from GLFW"
          if needRecreation || sizeChanged then do
            beforeSwapchainCreation
            let oldSwapchainLen = length (swapImgs swapInfo)
            logInfo "Recreating swapchain.."
            newScsd <- querySwapchainSupport pdev vulkanSurface
            newSwapInfo <- createSwapchain dev newScsd queues vulkanSurface swapchainResource oldSwapchainResource
            -- wait here is only to prevent concurrent wait & reset access to the fence
            runVk $ vkWaitForFences dev 1 oldSwapchainFencePtr VK_TRUE (maxBound :: Word64)
            runVk $ vkResetFences dev 1 oldSwapchainFencePtr
            -- TODO not sure if this has to be presentQueue or if graphicsQueue is good enough
            runVk $ vkQueueSubmit (presentQueue queues) 0 VK_NULL oldSwapchainFence
            liftIO $ atomicWriteIORef swapInfoRef newSwapInfo
            let newSwapchainLen = length (swapImgs newSwapInfo)
            if oldSwapchainLen /= newSwapchainLen
            then redoDifferentLength else redoSameLength
            return AbortLoop
          else return ContinueLoop
        -- after glfwMainLoop exits, we need to wait for the frame to finish before deallocating things
        runVk $ vkWaitForFences dev 1 oldSwapchainFencePtr VK_TRUE (maxBound :: Word64)
        when shouldExit $ runVk $ vkDeviceWaitIdle dev
        logInfo "Finished waiting after main loop termination before deallocating."
    runVk $ vkDeviceWaitIdle dev
    return ()

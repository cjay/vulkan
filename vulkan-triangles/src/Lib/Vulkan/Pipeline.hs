{-# LANGUAGE DataKinds        #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE NamedFieldPuns   #-}
{-# LANGUAGE PolyKinds        #-}
{-# LANGUAGE RecordWildCards  #-}
{-# LANGUAGE Strict           #-}
{-# LANGUAGE TypeApplications #-}
module Lib.Vulkan.Pipeline
  ( createGraphicsPipeline
  , createRenderPass
  , createPipelineLayout
  ) where

import           Data.Bits
import           Graphics.Vulkan
import           Graphics.Vulkan.Core_1_0
import           Graphics.Vulkan.Ext.VK_KHR_swapchain
import           Graphics.Vulkan.Marshal.Create
import           Graphics.Vulkan.Marshal.Create.DataFrame
import           Numeric.DataFrame
import           Numeric.Dimensions

import           Lib.Program
import           Lib.Program.Foreign
import           Lib.Vulkan.Presentation


createGraphicsPipeline :: ( KnownDim (n :: k)
                          , VulkanDataFrame VkVertexInputAttributeDescription '[n])
                       => VkDevice
                       -> SwapchainInfo
                       -> VkVertexInputBindingDescription
                       -> Vector VkVertexInputAttributeDescription n
                       -> [VkPipelineShaderStageCreateInfo]
                       -> VkRenderPass
                       -> VkPipelineLayout
                       -> Program r VkPipeline
createGraphicsPipeline
    dev SwapchainInfo{ swapExtent } bindDesc attrDescs shaderDescs renderPass pipelineLayout =
  let -- vertex input
      vertexInputInfo = createVk @VkPipelineVertexInputStateCreateInfo
        $  set @"sType" VK_STRUCTURE_TYPE_PIPELINE_VERTEX_INPUT_STATE_CREATE_INFO
        &* set @"pNext" VK_NULL
        &* set @"flags" 0
        &* set @"vertexBindingDescriptionCount" 1
        &* setDFRef @"pVertexBindingDescriptions"
          (scalar bindDesc)
        &* set @"vertexAttributeDescriptionCount"
          (fromIntegral . totalDim $ dims `inSpaceOf` attrDescs)
        &* setDFRef @"pVertexAttributeDescriptions" attrDescs

      -- input assembly
      inputAssembly = createVk @VkPipelineInputAssemblyStateCreateInfo
        $  set @"sType" VK_STRUCTURE_TYPE_PIPELINE_INPUT_ASSEMBLY_STATE_CREATE_INFO
        &* set @"pNext" VK_NULL
        &* set @"flags" 0
        &* set @"topology" VK_PRIMITIVE_TOPOLOGY_TRIANGLE_LIST
        &* set @"primitiveRestartEnable" VK_FALSE

      -- viewports and scissors
      viewPort = createVk @VkViewport
        $  set @"x" 0
        &* set @"y" 0
        &* set @"width" (fromIntegral $ getField @"width" swapExtent)
        &* set @"height" (fromIntegral $ getField @"height" swapExtent)
        &* set @"minDepth" 0
        &* set @"maxDepth" 1

      scissor = createVk @VkRect2D
        $  set   @"extent" swapExtent
        &* setVk @"offset" ( set @"x" 0 &* set @"y" 0 )

      viewPortState = createVk @VkPipelineViewportStateCreateInfo
        $ set @"sType"
          VK_STRUCTURE_TYPE_PIPELINE_VIEWPORT_STATE_CREATE_INFO
        &* set @"pNext" VK_NULL
        &* set @"flags" 0
        &* set @"viewportCount" 1
        &* setVkRef @"pViewports" viewPort
        &* set @"scissorCount" 1
        &* setVkRef @"pScissors" scissor

      -- rasterizer
      rasterizer = createVk @VkPipelineRasterizationStateCreateInfo
        $  set @"sType" VK_STRUCTURE_TYPE_PIPELINE_RASTERIZATION_STATE_CREATE_INFO
        &* set @"pNext" VK_NULL
        &* set @"flags" 0
        &* set @"depthClampEnable" VK_FALSE
        &* set @"rasterizerDiscardEnable" VK_FALSE
        &* set @"polygonMode" VK_POLYGON_MODE_FILL
        &* set @"cullMode" VK_CULL_MODE_BACK_BIT
        &* set @"frontFace" VK_FRONT_FACE_CLOCKWISE
        &* set @"depthBiasEnable" VK_FALSE
        &* set @"depthBiasConstantFactor" 0
        &* set @"depthBiasClamp" 0
        &* set @"depthBiasSlopeFactor" 0
        &* set @"lineWidth" 1.0

      -- multisampling
      multisampling = createVk @VkPipelineMultisampleStateCreateInfo
        $  set @"sType" VK_STRUCTURE_TYPE_PIPELINE_MULTISAMPLE_STATE_CREATE_INFO
        &* set @"pNext" VK_NULL
        &* set @"flags" 0
        &* set @"sampleShadingEnable" VK_FALSE
        &* set @"rasterizationSamples" VK_SAMPLE_COUNT_1_BIT
        &* set @"minSampleShading" 1.0 -- Optional
        &* set @"pSampleMask" VK_NULL -- Optional
        &* set @"alphaToCoverageEnable" VK_FALSE -- Optional
        &* set @"alphaToOneEnable" VK_FALSE -- Optional

      -- Depth and stencil testing
      -- we will pass null pointer in a corresponding place

      -- color blending
      colorBlendAttachment = createVk @VkPipelineColorBlendAttachmentState
        $  set @"colorWriteMask"
            (   VK_COLOR_COMPONENT_R_BIT .|. VK_COLOR_COMPONENT_G_BIT
            .|. VK_COLOR_COMPONENT_B_BIT .|. VK_COLOR_COMPONENT_A_BIT )
        &* set @"blendEnable" VK_FALSE
        &* set @"srcColorBlendFactor" VK_BLEND_FACTOR_ONE -- Optional
        &* set @"dstColorBlendFactor" VK_BLEND_FACTOR_ZERO -- Optional
        &* set @"colorBlendOp" VK_BLEND_OP_ADD -- Optional
        &* set @"srcAlphaBlendFactor" VK_BLEND_FACTOR_ONE -- Optional
        &* set @"dstAlphaBlendFactor" VK_BLEND_FACTOR_ZERO -- Optional
        &* set @"alphaBlendOp" VK_BLEND_OP_ADD -- Optional

      colorBlending = createVk @VkPipelineColorBlendStateCreateInfo
        $  set @"sType" VK_STRUCTURE_TYPE_PIPELINE_COLOR_BLEND_STATE_CREATE_INFO
        &* set @"pNext" VK_NULL
        &* set @"flags" 0
        &* set @"logicOpEnable" VK_FALSE
        &* set @"logicOp" VK_LOGIC_OP_COPY -- Optional
        &* set @"attachmentCount" 1
        &* setVkRef @"pAttachments" colorBlendAttachment
        &* setAt @"blendConstants" @0 0.0 -- Optional
        &* setAt @"blendConstants" @1 0.0 -- Optional
        &* setAt @"blendConstants" @2 0.0 -- Optional
        &* setAt @"blendConstants" @3 0.0 -- Optional

      depthStencilState = createVk @VkPipelineDepthStencilStateCreateInfo
        $  set @"sType" VK_STRUCTURE_TYPE_PIPELINE_DEPTH_STENCIL_STATE_CREATE_INFO
        &* set @"pNext" VK_NULL
        &* set @"flags" 0
        &* set @"depthTestEnable" VK_TRUE
        &* set @"depthWriteEnable" VK_TRUE
        &* set @"depthCompareOp" VK_COMPARE_OP_LESS
        &* set @"depthBoundsTestEnable" VK_FALSE
        &* set @"minDepthBounds" 0.0
        &* set @"maxDepthBounds" 1.0
        &* set @"stencilTestEnable" VK_FALSE
        &* setVk @"front"
            (  set @"failOp" VK_STENCIL_OP_KEEP
            &* set @"passOp" VK_STENCIL_OP_KEEP
            &* set @"depthFailOp" VK_STENCIL_OP_KEEP
            &* set @"compareOp" VK_COMPARE_OP_NEVER
            &* set @"compareMask" 0
            &* set @"writeMask" 0
            &* set @"reference" 0
            )
        &* setVk @"back"
            (  set @"failOp" VK_STENCIL_OP_KEEP
            &* set @"passOp" VK_STENCIL_OP_KEEP
            &* set @"depthFailOp" VK_STENCIL_OP_KEEP
            &* set @"compareOp" VK_COMPARE_OP_NEVER
            &* set @"compareMask" 0
            &* set @"writeMask" 0
            &* set @"reference" 0
            )

    -- finally, create pipeline!
  in do
    let gpCreateInfo = createVk @VkGraphicsPipelineCreateInfo
          $  set @"sType" VK_STRUCTURE_TYPE_GRAPHICS_PIPELINE_CREATE_INFO
          &* set @"pNext" VK_NULL
          &* set @"flags" 0
          &* set @"stageCount" (fromIntegral $ length shaderDescs)
          &* setListRef @"pStages" shaderDescs
          &* setVkRef @"pVertexInputState" vertexInputInfo
          &* setVkRef @"pInputAssemblyState" inputAssembly
          &* set @"pTessellationState" VK_NULL
          &* setVkRef @"pViewportState" viewPortState
          &* setVkRef @"pRasterizationState" rasterizer
          &* setVkRef @"pMultisampleState" multisampling
          &* setVkRef @"pDepthStencilState" depthStencilState
          &* setVkRef @"pColorBlendState" colorBlending
          &* set @"pDynamicState" VK_NULL
          &* set @"layout" pipelineLayout
          &* set @"renderPass" renderPass
          &* set @"subpass" 0
          &* set @"basePipelineHandle" VK_NULL_HANDLE
          &* set @"basePipelineIndex" (-1)

    allocResource
      (\gp -> liftIO $ vkDestroyPipeline dev gp VK_NULL) $
      withVkPtr gpCreateInfo $ \gpciPtr -> allocaPeek $
        runVk . vkCreateGraphicsPipelines dev VK_NULL 1 gpciPtr VK_NULL


createPipelineLayout :: VkDevice -> VkDescriptorSetLayout -> Program r VkPipelineLayout
createPipelineLayout dev dsl = do
  let plCreateInfo = createVk @VkPipelineLayoutCreateInfo
        $  set @"sType" VK_STRUCTURE_TYPE_PIPELINE_LAYOUT_CREATE_INFO
        &* set @"pNext" VK_NULL
        &* set @"flags" 0
        &* set @"setLayoutCount"         1       -- Optional
        &* setListRef @"pSetLayouts"     [dsl]   -- Optional
        &* set @"pushConstantRangeCount" 0       -- Optional
        &* set @"pPushConstantRanges"    VK_NULL -- Optional
  allocResource
    (\pl -> liftIO $ vkDestroyPipelineLayout dev pl VK_NULL) $
    withVkPtr plCreateInfo $ \plciPtr -> allocaPeek $
      runVk . vkCreatePipelineLayout dev plciPtr VK_NULL


createRenderPass :: VkDevice
                 -> SwapchainInfo
                 -> VkFormat
                 -> Program r VkRenderPass
createRenderPass dev SwapchainInfo{ swapImgFormat } depthFormat =
  let -- attachment description
      colorAttachment = createVk @VkAttachmentDescription
        $  set @"flags" 0
        &* set @"format" swapImgFormat
        &* set @"samples" VK_SAMPLE_COUNT_1_BIT
        &* set @"loadOp" VK_ATTACHMENT_LOAD_OP_CLEAR
        &* set @"storeOp" VK_ATTACHMENT_STORE_OP_STORE
        &* set @"stencilLoadOp" VK_ATTACHMENT_LOAD_OP_DONT_CARE
        &* set @"stencilStoreOp" VK_ATTACHMENT_STORE_OP_DONT_CARE
        &* set @"initialLayout" VK_IMAGE_LAYOUT_UNDEFINED
        &* set @"finalLayout" VK_IMAGE_LAYOUT_PRESENT_SRC_KHR

      depthAttachment = createVk @VkAttachmentDescription
        $  set @"flags" 0
        &* set @"format" depthFormat
        &* set @"samples" VK_SAMPLE_COUNT_1_BIT
        &* set @"loadOp" VK_ATTACHMENT_LOAD_OP_CLEAR
        &* set @"storeOp" VK_ATTACHMENT_STORE_OP_DONT_CARE
        &* set @"stencilLoadOp" VK_ATTACHMENT_LOAD_OP_DONT_CARE
        &* set @"stencilStoreOp" VK_ATTACHMENT_STORE_OP_DONT_CARE
        &* set @"initialLayout" VK_IMAGE_LAYOUT_UNDEFINED
        &* set @"finalLayout" VK_IMAGE_LAYOUT_DEPTH_STENCIL_ATTACHMENT_OPTIMAL

      -- subpasses and attachment references
      colorAttachmentRef = createVk @VkAttachmentReference
        $  set @"attachment" 0
        &* set @"layout" VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL

      depthAttachmentRef = createVk @VkAttachmentReference
        $  set @"attachment" 1
        &* set @"layout" VK_IMAGE_LAYOUT_DEPTH_STENCIL_ATTACHMENT_OPTIMAL

      subpass = createVk @VkSubpassDescription
        $  set @"pipelineBindPoint" VK_PIPELINE_BIND_POINT_GRAPHICS
        &* set @"colorAttachmentCount" 1
        &* setVkRef @"pColorAttachments" colorAttachmentRef
        &* setVkRef @"pDepthStencilAttachment" depthAttachmentRef
        &* set @"pPreserveAttachments" VK_NULL
        &* set @"pInputAttachments" VK_NULL

      -- subpass dependencies
      dependency = createVk @VkSubpassDependency
        $  set @"srcSubpass" VK_SUBPASS_EXTERNAL
        &* set @"dstSubpass" 0
        &* set @"srcStageMask" VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT
        &* set @"srcAccessMask" 0
        &* set @"dstStageMask" VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT
        &* set @"dstAccessMask"
            (   VK_ACCESS_COLOR_ATTACHMENT_READ_BIT
            .|. VK_ACCESS_COLOR_ATTACHMENT_WRITE_BIT )

      -- render pass
      rpCreateInfo = createVk @VkRenderPassCreateInfo
        $  set @"sType" VK_STRUCTURE_TYPE_RENDER_PASS_CREATE_INFO
        &* set @"pNext" VK_NULL
        &* setListCountAndRef @"attachmentCount" @"pAttachments" [colorAttachment, depthAttachment]
        &* set @"subpassCount" 1
        &* setVkRef @"pSubpasses" subpass
        &* set @"dependencyCount" 1
        &* setVkRef @"pDependencies" dependency

  in allocResource
       (\rp -> liftIO $ vkDestroyRenderPass dev rp VK_NULL) $
       withVkPtr rpCreateInfo $ \rpciPtr -> allocaPeek $
         runVk . vkCreateRenderPass dev rpciPtr VK_NULL

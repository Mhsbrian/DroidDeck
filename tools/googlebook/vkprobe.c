/* Minimal Vulkan check: device creation, a fill + offscreen clear, fence wait, readback, timing. */
#include <vulkan/vulkan.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#define CK(x) do { VkResult r_ = (x); if (r_ != VK_SUCCESS) { fprintf(stderr, "%s failed: %d\n", #x, r_); exit(1); } } while (0)
static double now(void) { struct timespec t; clock_gettime(CLOCK_MONOTONIC, &t); return t.tv_sec + t.tv_nsec / 1e9; }
static uint32_t memtype(VkPhysicalDevice pd, uint32_t bits, VkMemoryPropertyFlags want) {
  VkPhysicalDeviceMemoryProperties mp; vkGetPhysicalDeviceMemoryProperties(pd, &mp);
  for (uint32_t i = 0; i < mp.memoryTypeCount; i++)
    if ((bits & (1u << i)) && (mp.memoryTypes[i].propertyFlags & want) == want) return i;
  fprintf(stderr, "no memory type\n"); exit(1);
}
int main(int argc, char **argv) {
  uint32_t vendor = argc > 1 ? strtoul(argv[1], 0, 16) : 0;
  VkApplicationInfo ai = { VK_STRUCTURE_TYPE_APPLICATION_INFO, 0, "vkprobe", 1, 0, 0, VK_API_VERSION_1_1 };
  VkInstanceCreateInfo ici = { VK_STRUCTURE_TYPE_INSTANCE_CREATE_INFO, 0, 0, &ai };
  VkInstance inst; CK(vkCreateInstance(&ici, 0, &inst));
  uint32_t n = 8; VkPhysicalDevice pds[8]; CK(vkEnumeratePhysicalDevices(inst, &n, pds));
  VkPhysicalDevice pd = 0; VkPhysicalDeviceProperties p;
  for (uint32_t i = 0; i < n; i++) { vkGetPhysicalDeviceProperties(pds[i], &p); if (!vendor || p.vendorID == vendor) { pd = pds[i]; break; } }
  if (!pd) { fprintf(stderr, "no device for vendor %x\n", vendor); return 1; }
  printf("device: %s (vendor %04x, driver %u)\n", p.deviceName, p.vendorID, p.driverVersion);
  float prio = 1; VkDeviceQueueCreateInfo qci = { VK_STRUCTURE_TYPE_DEVICE_QUEUE_CREATE_INFO, 0, 0, 0, 1, &prio };
  VkDeviceCreateInfo dci = { VK_STRUCTURE_TYPE_DEVICE_CREATE_INFO, 0, 0, 1, &qci };
  VkDevice dev; CK(vkCreateDevice(pd, &dci, 0, &dev));
  VkQueue q; vkGetDeviceQueue(dev, 0, 0, &q);
  /* 256 MiB device-local buffer for fill bandwidth, 8 MiB host buffer for readback. */
  VkDeviceSize big = 256u << 20, W = 1920, H = 1080, rb = W * H * 4;
  VkBufferCreateInfo bci = { VK_STRUCTURE_TYPE_BUFFER_CREATE_INFO, 0, 0, big, VK_BUFFER_USAGE_TRANSFER_DST_BIT };
  VkBuffer bb; CK(vkCreateBuffer(dev, &bci, 0, &bb));
  VkMemoryRequirements mr; vkGetBufferMemoryRequirements(dev, bb, &mr);
  VkMemoryAllocateInfo mai = { VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO, 0, mr.size, memtype(pd, mr.memoryTypeBits, VK_MEMORY_PROPERTY_DEVICE_LOCAL_BIT) };
  VkDeviceMemory bm; CK(vkAllocateMemory(dev, &mai, 0, &bm)); CK(vkBindBufferMemory(dev, bb, bm, 0));
  bci.size = rb; VkBuffer hb; CK(vkCreateBuffer(dev, &bci, 0, &hb));
  vkGetBufferMemoryRequirements(dev, hb, &mr);
  mai.allocationSize = mr.size; mai.memoryTypeIndex = memtype(pd, mr.memoryTypeBits, VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT | VK_MEMORY_PROPERTY_HOST_COHERENT_BIT);
  VkDeviceMemory hm; CK(vkAllocateMemory(dev, &mai, 0, &hm)); CK(vkBindBufferMemory(dev, hb, hm, 0));
  VkImageCreateInfo imci = { VK_STRUCTURE_TYPE_IMAGE_CREATE_INFO, 0, 0, VK_IMAGE_TYPE_2D, VK_FORMAT_R8G8B8A8_UNORM, { W, H, 1 }, 1, 1,
    VK_SAMPLE_COUNT_1_BIT, VK_IMAGE_TILING_OPTIMAL, VK_IMAGE_USAGE_TRANSFER_DST_BIT | VK_IMAGE_USAGE_TRANSFER_SRC_BIT };
  VkImage img; CK(vkCreateImage(dev, &imci, 0, &img));
  vkGetImageMemoryRequirements(dev, img, &mr);
  mai.allocationSize = mr.size; mai.memoryTypeIndex = memtype(pd, mr.memoryTypeBits, VK_MEMORY_PROPERTY_DEVICE_LOCAL_BIT);
  VkDeviceMemory im; CK(vkAllocateMemory(dev, &mai, 0, &im)); CK(vkBindImageMemory(dev, img, im, 0));
  VkCommandPoolCreateInfo cpi = { VK_STRUCTURE_TYPE_COMMAND_POOL_CREATE_INFO, 0, 0, 0 };
  VkCommandPool pool; CK(vkCreateCommandPool(dev, &cpi, 0, &pool));
  VkCommandBufferAllocateInfo cai = { VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO, 0, pool, VK_COMMAND_BUFFER_LEVEL_PRIMARY, 1 };
  VkCommandBuffer cb; CK(vkAllocateCommandBuffers(dev, &cai, &cb));
  VkFenceCreateInfo fci = { VK_STRUCTURE_TYPE_FENCE_CREATE_INFO };
  VkFence f; CK(vkCreateFence(dev, &fci, 0, &f));
  VkCommandBufferBeginInfo bi = { VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO };
  VkSubmitInfo si = { VK_STRUCTURE_TYPE_SUBMIT_INFO, 0, 0, 0, 0, 1, &cb };
  /* Offscreen clear to a known colour, copy to host, verify. 0.5 may round to 127 or 128. */
  CK(vkBeginCommandBuffer(cb, &bi));
  VkImageSubresourceRange rng = { VK_IMAGE_ASPECT_COLOR_BIT, 0, 1, 0, 1 };
  VkImageMemoryBarrier b1 = { VK_STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER, 0, 0, VK_ACCESS_TRANSFER_WRITE_BIT, VK_IMAGE_LAYOUT_UNDEFINED,
    VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL, VK_QUEUE_FAMILY_IGNORED, VK_QUEUE_FAMILY_IGNORED, img, rng };
  vkCmdPipelineBarrier(cb, VK_PIPELINE_STAGE_TOP_OF_PIPE_BIT, VK_PIPELINE_STAGE_TRANSFER_BIT, 0, 0, 0, 0, 0, 1, &b1);
  VkClearColorValue cc = { .float32 = { 1.0f, 0.5f, 0.0f, 1.0f } };
  vkCmdClearColorImage(cb, img, VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL, &cc, 1, &rng);
  VkImageMemoryBarrier b2 = b1; b2.srcAccessMask = VK_ACCESS_TRANSFER_WRITE_BIT; b2.dstAccessMask = VK_ACCESS_TRANSFER_READ_BIT;
  b2.oldLayout = VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL; b2.newLayout = VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL;
  vkCmdPipelineBarrier(cb, VK_PIPELINE_STAGE_TRANSFER_BIT, VK_PIPELINE_STAGE_TRANSFER_BIT, 0, 0, 0, 0, 0, 1, &b2);
  VkBufferImageCopy bic = { 0, 0, 0, { VK_IMAGE_ASPECT_COLOR_BIT, 0, 0, 1 }, { 0, 0, 0 }, { W, H, 1 } };
  vkCmdCopyImageToBuffer(cb, img, VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL, hb, 1, &bic);
  CK(vkEndCommandBuffer(cb));
  double t0 = now(); CK(vkQueueSubmit(q, 1, &si, f)); CK(vkWaitForFences(dev, 1, &f, 1, 5000000000ull)); double t1 = now();
  uint8_t *px; CK(vkMapMemory(dev, hm, 0, rb, 0, (void **)&px));
  int ok = px[0] == 255 && (px[1] == 127 || px[1] == 128) && px[2] == 0 && px[3] == 255 && memcmp(px, px + rb - 4, 4) == 0;
  printf("clear 1920x1080 + readback: %s (first pixel %u,%u,%u,%u) in %.2f ms\n", ok ? "OK" : "MISMATCH", px[0], px[1], px[2], px[3], (t1 - t0) * 1e3);
  /* Fill bandwidth: 20 x 256 MiB device-local fills in one submit. */
  CK(vkResetFences(dev, 1, &f)); CK(vkResetCommandPool(dev, pool, 0)); CK(vkBeginCommandBuffer(cb, &bi));
  for (int i = 0; i < 20; i++) vkCmdFillBuffer(cb, bb, 0, VK_WHOLE_SIZE, 0xdeadbeef);
  CK(vkEndCommandBuffer(cb));
  t0 = now(); CK(vkQueueSubmit(q, 1, &si, f)); CK(vkWaitForFences(dev, 1, &f, 1, 10000000000ull)); t1 = now();
  printf("fill: 20 x 256 MiB in %.2f ms = %.1f GB/s\n", (t1 - t0) * 1e3, 20.0 * big / (t1 - t0) / 1e9);
  vkDeviceWaitIdle(dev);
  printf("RESULT %s\n", ok ? "PASS" : "FAIL");
  return ok ? 0 : 2;
}

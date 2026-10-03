export interface DesktopApi {
  postMessage(message: unknown): void;
}

export function acquireDesktopApi(
  factory?: () => DesktopApi,
): DesktopApi | undefined {
  return factory?.();
}

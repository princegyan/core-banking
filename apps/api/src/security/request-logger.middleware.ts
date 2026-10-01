import { Injectable, NestMiddleware } from '@nestjs/common';
import { Request, Response, NextFunction } from 'express';
import { SupabaseService } from '../database/supabase.service';
import type { AuthenticatedUser } from '../auth/types/authenticated-user';

@Injectable()
export class RequestLoggerMiddleware implements NestMiddleware {
  constructor(private readonly supabase: SupabaseService) {}

  use(req: Request, res: Response, next: NextFunction) {
    const start = Date.now();
    const client = this.supabase.getClient();

    res.on('finish', async () => {
      const responseTime = Date.now() - start;
      const user = (req as any).user as AuthenticatedUser | undefined;

      const logData = {
        tenant_id: user?.tenantId || null,
        user_id: user?.id || null,
        method: req.method,
        path: req.originalUrl || req.path,
        status_code: res.statusCode,
        response_time_ms: responseTime,
        ip_address: req.ip || req.socket.remoteAddress,
        user_agent: req.get('user-agent') || null,
        idempotency_key: req.get('x-idempotency-key') || null,
        request_body_size: req.get('content-length') ? parseInt(req.get('content-length')!, 10) : null,
        error_message: res.statusCode >= 400 ? res.statusMessage : null,
      };

      try {
        await client.from('api_request_log').insert(logData);
      } catch (err) {
        console.error('Failed to log API request:', err);
      }
    });

    next();
  }
}

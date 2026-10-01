import { ArgumentMetadata, Injectable, PipeTransform } from '@nestjs/common';

@Injectable()
export class SanitizePipe implements PipeTransform {
  transform(value: any, _metadata: ArgumentMetadata) {
    return this.sanitize(value);
  }

  private sanitize(obj: any): any {
    if (typeof obj === 'string') {
      return obj.replace(/<[^>]*>?/gm, '');
    }

    if (Array.isArray(obj)) {
      return obj.map((item) => this.sanitize(item));
    }

    if (obj !== null && typeof obj === 'object') {
      const result: Record<string, any> = {};
      for (const [key, val] of Object.entries(obj)) {
        result[key] = this.sanitize(val);
      }
      return result;
    }

    return obj;
  }
}
